use worker::js_sys;
use worker::wasm_bindgen::{JsCast, JsValue};
use worker::wasm_bindgen_futures::JsFuture;
use worker::web_sys;
use worker::{Context, Env, Request, Result, event};

use crate::{
    DOWN_HEADERS, INSPECT_LIMIT, Verdict, is_gateway_body, render, should_inspect_body,
    verdict_for_status,
};

/// Every request to the routes in wrangler.toml. Nothing is logged and nothing
/// is cached here: the origin's response goes back as the very object fetch
/// returned, so its body streams and its headers (Set-Cookie included), status
/// and redirects are the origin's.
#[event(fetch)]
async fn fetch(request: Request, _env: Env, ctx: Context) -> Result<web_sys::Response> {
    // Should this Worker ever throw, Cloudflare sends the request on to the
    // origin as if the Worker were not there.
    ctx.pass_through_on_exception();
    let host = request
        .url()
        .ok()
        .and_then(|url| url.host_str().map(str::to_owned))
        .unwrap_or_default();
    let scope: web_sys::WorkerGlobalScope = js_sys::global().unchecked_into();
    // The incoming request's redirect mode is "manual": a redirect comes back as it is.
    let origin = match JsFuture::from(scope.fetch_with_request(request.inner())).await {
        Ok(value) => value.dyn_into::<web_sys::Response>().ok(),
        Err(_) => None,
    };
    let Some(origin) = origin else {
        return down(&host);
    };
    match verdict_for_status(origin.status()) {
        Verdict::PassThrough => Ok(origin),
        Verdict::Down => down(&host),
        Verdict::Inspect => {
            let headers = origin.headers();
            let length = headers
                .get("content-length")
                .ok()
                .flatten()
                .and_then(|value| value.trim().parse().ok());
            let kind = headers.get("content-type").ok().flatten();
            if !should_inspect_body(length, kind.as_deref()) {
                return Ok(origin);
            }
            match read_prefix(&origin).await {
                Some(body) if is_gateway_body(&body) => down(&host),
                _ => Ok(origin),
            }
        }
    }
}

/// The body of a copy of `response` when it is UTF-8 of at most INSPECT_LIMIT
/// bytes; None for anything longer, where reading stops. The original's body
/// still streams to the client in full.
async fn read_prefix(response: &web_sys::Response) -> Option<String> {
    let copy = response.clone().ok()?;
    let Some(stream) = copy.body() else {
        return Some(String::new());
    };
    let reader: web_sys::ReadableStreamDefaultReader = stream.get_reader().dyn_into().ok()?;
    let limit = usize::try_from(INSPECT_LIMIT).ok()?;
    let mut bytes = Vec::new();
    loop {
        let step = JsFuture::from(reader.read()).await.ok()?;
        let done = js_sys::Reflect::get(&step, &JsValue::from_str("done"))
            .ok()?
            .as_bool()?;
        if done {
            break;
        }
        let chunk: js_sys::Uint8Array = js_sys::Reflect::get(&step, &JsValue::from_str("value"))
            .ok()?
            .dyn_into()
            .ok()?;
        let chunk_len = usize::try_from(chunk.length()).ok()?;
        if bytes.len().saturating_add(chunk_len) > limit {
            // Cancels this copy only; the original keeps its body.
            let _cancelled = reader.cancel();
            return None;
        }
        bytes.extend_from_slice(&chunk.to_vec());
    }
    String::from_utf8(bytes).ok()
}

fn down(host: &str) -> Result<web_sys::Response> {
    let headers = web_sys::Headers::new()?;
    for (name, value) in DOWN_HEADERS {
        headers.set(name, value)?;
    }
    let init = web_sys::ResponseInit::new();
    init.set_status(503);
    init.set_headers(&headers);
    Ok(web_sys::Response::new_with_opt_str_and_init(
        Some(&render(host)),
        &init,
    )?)
}
