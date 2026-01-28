declare module 'http-mitm-proxy' {
  import { IncomingMessage, ServerResponse } from 'http';
  import { Socket } from 'net';

  interface ProxyContext {
    clientToProxyRequest: IncomingMessage;
    proxyToClientResponse: ServerResponse;
    proxyToServerRequestOptions: {
      headers: Record<string, string | string[]>;
      host?: string;
      port?: number;
      path?: string;
      method?: string;
    };
    isSSL: boolean;
    addRequestFilter(filter: (ctx: ProxyContext, callback: (err?: Error) => void) => void): void;
    addResponseFilter(filter: (ctx: ProxyContext, callback: (err?: Error) => void) => void): void;
  }

  interface ProxyOptions {
    port?: number;
    sslCaDir?: string;
    host?: string;
    timeout?: number;
    keepAlive?: boolean;
    httpAgent?: unknown;
    httpsAgent?: unknown;
    forceSNI?: boolean;
    forceChunkedRequest?: boolean;
  }

  class Proxy {
    constructor();
    listen(options: ProxyOptions, callback?: () => void): void;
    close(callback?: () => void): void;
    onError(callback: (ctx: ProxyContext | null, err: Error, errorKind?: string) => void): void;
    onRequest(callback: (ctx: ProxyContext, callback: (err?: Error) => void) => void): void;
    onResponse(callback: (ctx: ProxyContext, callback: (err?: Error) => void) => void): void;
    onConnect(callback: (req: IncomingMessage, socket: Socket, head: Buffer, callback: (err?: Error) => void) => void): void;
    onRequestData(callback: (ctx: ProxyContext, chunk: Buffer, callback: (err?: Error, chunk?: Buffer) => void) => void): void;
    onResponseData(callback: (ctx: ProxyContext, chunk: Buffer, callback: (err?: Error, chunk?: Buffer) => void) => void): void;
    onRequestEnd(callback: (ctx: ProxyContext, callback: (err?: Error) => void) => void): void;
    onResponseEnd(callback: (ctx: ProxyContext, callback: (err?: Error) => void) => void): void;
  }

  export = Proxy;
}
