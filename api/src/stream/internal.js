import { request } from "undici";
import { Readable } from "node:stream";
import { closeRequest, closeResponse, getHeaders, pipe } from "./shared.js";
import { handleHlsPlaylist, isHlsResponse, probeInternalHLSTunnel } from "./internal-hls.js";

const CHUNK_SIZE = BigInt(8e6); // 8 MB
const min = (a, b) => a < b ? a : b;

const serviceNeedsChunks = new Set(["youtube", "vk"]);

async function* readChunks(streamInfo, start = 0n, endExclusive) {
    let read = start;
    while (read < endExclusive) {
        if (streamInfo.controller.signal.aborted) {
            throw new Error("controller aborted");
        }

        const chunkEnd = min(read + CHUNK_SIZE, endExclusive) - 1n;
        let chunk, attempts = 0;
        while (true) {
            chunk = await request(streamInfo.url, {
                headers: {
                    ...getHeaders(streamInfo.service),
                    Range: `bytes=${read}-${chunkEnd}`
                },
                dispatcher: streamInfo.dispatcher,
                signal: streamInfo.controller.signal,
                maxRedirections: 4
            });

            if (chunk.statusCode === 403 && streamInfo.transplant && attempts++ < 3) {
                await chunk.body.dump();
                await streamInfo.transplant(streamInfo.dispatcher);
                continue;
            }

            if (chunk.statusCode !== 200 && chunk.statusCode !== 206) {
                await chunk.body.dump();
                throw new Error(`media request failed with status ${chunk.statusCode}`);
            }

            break;
        }

        const expected = min(CHUNK_SIZE, endExclusive - read);
        const received = BigInt(chunk.headers['content-length']);

        if (received < expected / 2n) {
            closeRequest(streamInfo.controller);
        }

        for await (const data of chunk.body) {
            yield data;
        }

        if (received <= 0n) {
            break;
        }
        read += received;
    }
}

async function handleChunkedStream(streamInfo, res) {
    const { signal } = streamInfo.controller;
    const cleanup = () => {
        if (!res.headersSent) {
            res.removeHeader('content-length');
            res.removeHeader('content-type');
        }
        closeResponse(res);
        closeRequest(streamInfo.controller);
    };

    try {
        let req;
        for (let attempts = 0; ; attempts++) {
            req = await fetch(streamInfo.url, {
                headers: getHeaders(streamInfo.service),
                method: 'HEAD',
                dispatcher: streamInfo.dispatcher,
                signal
            });

            streamInfo.url = req.url;
            if (req.status !== 403 || !streamInfo.transplant || attempts >= 3) break;
            await streamInfo.transplant(streamInfo.dispatcher);
        }

        const size = BigInt(req.headers.get('content-length'));

        if (req.status !== 200 || !size) {
            return cleanup();
        }

        let start = 0n;
        let end = size - 1n;
        let isRange = false;
        const rangeHeader = streamInfo.headers?.get('range');
        if (rangeHeader) {
            const match = /^bytes=(\d*)-(\d*)$/i.exec(String(rangeHeader).trim());
            if (!match || (!match[1] && !match[2])) {
                res.status(416);
                res.setHeader('content-range', `bytes */${size}`);
                return res.end();
            }
            if (match[1] && match[2]) {
                start = BigInt(match[1]);
                end = min(BigInt(match[2]), size - 1n);
            } else if (match[1]) {
                start = BigInt(match[1]);
                end = size - 1n;
            } else {
                const suffix = BigInt(match[2]);
                start = suffix >= size ? 0n : size - suffix;
                end = size - 1n;
            }
            if (start >= size || start > end) {
                res.status(416);
                res.setHeader('content-range', `bytes */${size}`);
                return res.end();
            }
            isRange = true;
        }

        const generator = readChunks(streamInfo, start, end + 1n);

        const abortGenerator = () => {
            generator.return();
            signal.removeEventListener('abort', abortGenerator);
        }

        signal.addEventListener('abort', abortGenerator);

        const stream = Readable.from(generator);

        res.setHeader('accept-ranges', 'bytes');
        const contentType = req.headers.get('content-type');
        if (contentType) res.setHeader('content-type', contentType);
        if (isRange) {
            res.status(206);
            res.setHeader('content-range', `bytes ${start}-${end}/${size}`);
            res.setHeader('content-length', (end - start + 1n).toString());
        } else {
            res.setHeader('content-length', size.toString());
        }

        pipe(stream, res, cleanup);
    } catch {
        cleanup();
    }
}

async function handleGenericStream(streamInfo, res) {
    const { signal } = streamInfo.controller;
    const cleanup = () => res.end();

    try {
        const fileResponse = await request(streamInfo.url, {
            headers: {
                ...Object.fromEntries(streamInfo.headers),
                host: undefined
            },
            dispatcher: streamInfo.dispatcher,
            signal,
            maxRedirections: 16
        });

        res.status(fileResponse.statusCode);
        fileResponse.body.on('error', () => {});

        const isHls = isHlsResponse(fileResponse, streamInfo);

        for (const [ name, value ] of Object.entries(fileResponse.headers)) {
            if (!isHls || name.toLowerCase() !== 'content-length') {
                res.setHeader(name, value);
            }
        }

        if (fileResponse.statusCode < 200 || fileResponse.statusCode > 299) {
            return cleanup();
        }

        if (isHls) {
            await handleHlsPlaylist(streamInfo, fileResponse, res);
        } else {
            pipe(fileResponse.body, res, cleanup);
        }
    } catch {
        closeRequest(streamInfo.controller);
        cleanup();
    }
}

export function internalStream(streamInfo, res) {
    if (streamInfo.headers) {
        streamInfo.headers.delete('icy-metadata');
    }

    if (serviceNeedsChunks.has(streamInfo.service) && !streamInfo.isHLS) {
        return handleChunkedStream(streamInfo, res);
    }

    return handleGenericStream(streamInfo, res);
}

export async function probeInternalTunnel(streamInfo) {
    try {
        const signal = AbortSignal.timeout(3000);
        const headers = {
            ...Object.fromEntries(streamInfo.headers || []),
            ...getHeaders(streamInfo.service),
            host: undefined,
            range: undefined
        };

        if (streamInfo.isHLS) {
            return probeInternalHLSTunnel({
                ...streamInfo,
                signal,
                headers
            });
        }

        const response = await request(streamInfo.url, {
            method: 'HEAD',
            headers,
            dispatcher: streamInfo.dispatcher,
            signal,
            maxRedirections: 16
        });

        if (response.statusCode !== 200)
            throw "status is not 200 OK";

        const size = +response.headers['content-length'];
        if (isNaN(size))
            throw "content-length is not a number";

        return size;
    } catch {}
}
