import { Agent, ProxyAgent, request } from "undici";
import { create as contentDisposition } from "content-disposition-header";

import { destroyInternalStream } from "./manage.js";
import { getHeaders, closeRequest, closeResponse, pipe } from "./shared.js";

const defaultAgent = new Agent();
const outboundProxyUrl = process.env.OUTBOUND_PROXY_URL?.trim();
const youtubeProxyAgent = outboundProxyUrl ? new ProxyAgent(outboundProxyUrl) : undefined;

export default async function (streamInfo, res) {
    const abortController = new AbortController();
    const shutdown = () => (
        closeRequest(abortController),
        closeResponse(res),
        destroyInternalStream(streamInfo.urls)
    );

    try {
        res.setHeader('Cross-Origin-Resource-Policy', 'cross-origin');
        res.setHeader('Content-disposition', contentDisposition(streamInfo.filename));

        const requestHeaders = {
            ...getHeaders(streamInfo.service),
        };
        if (streamInfo.range) {
            requestHeaders.Range = streamInfo.range;
        }

        const isLocalTunnel = typeof streamInfo.urls === "string" && streamInfo.urls.startsWith("http://127.0.0.1");
        const { body: stream, headers, statusCode } = await request(streamInfo.urls, {
            headers: requestHeaders,
            signal: abortController.signal,
            maxRedirections: 16,
            dispatcher: (!isLocalTunnel && streamInfo.service === "youtube" && youtubeProxyAgent) ? youtubeProxyAgent : defaultAgent,
        });

        res.status(statusCode);

        for (const headerName of ['accept-ranges', 'content-type', 'content-length', 'content-range']) {
            if (headers[headerName]) {
                res.setHeader(headerName, headers[headerName]);
            }
        }

        pipe(stream, res, shutdown);
    } catch {
        shutdown();
    }
}
