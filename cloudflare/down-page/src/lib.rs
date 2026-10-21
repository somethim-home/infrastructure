//! A Cloudflare Worker in front of the public sites (arbikullakshi.com, www., and
//! hypernova.arbikullakshi.com). It passes every request to the origin (the home
//! server, through the Cloudflare Tunnel) and returns the origin's response
//! untouched: status, headers, cookies, redirects and a streamed body. Only when
//! the origin cannot be reached does it answer itself, with a 503 "server is
//! down" page and `Retry-After`. See docs/edge.md, "The down page".

mod decision;
mod page;

pub use decision::{
    INSPECT_LIMIT, Verdict, is_gateway_body, should_inspect_body, verdict_for_status,
};
pub use page::{DOWN_HEADERS, RETRY_AFTER_SECONDS, render, site_name};

#[cfg(target_arch = "wasm32")]
mod entry;
