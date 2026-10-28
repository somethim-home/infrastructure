/// What to do with the origin's answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// The origin answered: return its response as it is.
    PassThrough,
    /// Cloudflare could not reach the origin: show the down page.
    Down,
    /// A gateway error that the app itself may have sent: look at the body.
    Inspect,
}

/// Cloudflare answers for an origin it cannot reach with these statuses. 520
/// to 527 are Cloudflare's own origin errors (521 or 522 while the server is
/// off); the app never sends them. 530 is a Cloudflare Tunnel's, kept from when
/// the site was served through one. 502 and 504 come from Cloudflare or
/// Traefik when what is behind them does not answer, but an app may send them
/// too, so those are only the down page when the body is a gateway's.
pub fn verdict_for_status(status: u16) -> Verdict {
    match status {
        520..=527 | 530 => Verdict::Down,
        502 | 504 => Verdict::Inspect,
        _ => Verdict::PassThrough,
    }
}

/// The most of a 502 or 504 body read to tell a gateway's from the app's. A
/// longer one is the app's and passes through; reading stops at this size
/// even when no `Content-Length` was sent.
pub const INSPECT_LIMIT: u64 = 16 * 1024;

/// Whether a 502 or 504 may be a gateway's and is worth reading: no body type
/// or a text or HTML one (an app's JSON or event stream is never read), and no
/// longer than [`INSPECT_LIMIT`] when its length is known.
pub fn should_inspect_body(content_length: Option<u64>, content_type: Option<&str>) -> bool {
    let textual = content_type.is_none_or(|value| {
        let essence = value.split(';').next().unwrap_or_default().trim();
        essence.eq_ignore_ascii_case("text/html") || essence.eq_ignore_ascii_case("text/plain")
    });
    textual && content_length.is_none_or(|length| length <= INSPECT_LIMIT)
}

/// Whether a 502 or 504 body is a gateway's rather than the app's: empty
/// (cloudflared's own), `error code: <digits>` (what a Worker's subrequest gets
/// for an edge error), Cloudflare's HTML error page, or Traefik's exact
/// `Bad Gateway` / `Gateway Timeout` when the app's container is not up.
pub fn is_gateway_body(body: &str) -> bool {
    let body = body.trim();
    if body.is_empty() || body == "Bad Gateway" || body == "Gateway Timeout" {
        return true;
    }
    if let Some(code) = body.strip_prefix("error code: ") {
        return !code.is_empty() && code.bytes().all(|b| b.is_ascii_digit());
    }
    body.contains("cf-error-details")
        || (body.contains("id=\"cf-wrapper\"") && body.contains("Cloudflare"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tunnel_and_edge_errors_are_down() {
        for status in [530, 520, 521, 522, 523, 524, 525, 526, 527] {
            assert_eq!(verdict_for_status(status), Verdict::Down, "{status}");
        }
    }

    #[test]
    fn gateway_errors_are_inspected() {
        assert_eq!(verdict_for_status(502), Verdict::Inspect);
        assert_eq!(verdict_for_status(504), Verdict::Inspect);
    }

    #[test]
    fn everything_the_apps_send_passes_through() {
        for status in [
            101, 200, 201, 204, 206, 301, 302, 303, 304, 307, 308, 400, 401, 403, 404, 405, 409,
            410, 413, 429, 500, 501, 503, 505, 511, 528, 529, 531, 599,
        ] {
            assert_eq!(verdict_for_status(status), Verdict::PassThrough, "{status}");
        }
    }

    #[test]
    fn gateway_bodies_are_recognised() {
        assert!(is_gateway_body(""));
        assert!(is_gateway_body("  \n"));
        assert!(is_gateway_body("error code: 502"));
        assert!(is_gateway_body("error code: 1033\n"));
        assert!(is_gateway_body("Bad Gateway"));
        assert!(is_gateway_body("Gateway Timeout\n"));
        let page = r#"<!DOCTYPE html><html><head><title>Bad gateway | Cloudflare</title></head><body><div id="cf-wrapper"><div id="cf-error-details">Error code 502</div></div></body></html>"#;
        assert!(is_gateway_body(page));
    }

    #[test]
    fn app_bodies_pass_through() {
        assert!(!is_gateway_body("Bad Gateway: the model is loading"));
        assert!(!is_gateway_body(
            r#"{"error":"the model did not answer in time"}"#
        ));
        assert!(!is_gateway_body("error code: "));
        assert!(!is_gateway_body("error code: 502; the upstream said so"));
        assert!(!is_gateway_body(
            "<html><body>Cloudflare is mentioned in this article</body></html>"
        ));
    }

    #[test]
    fn only_small_bodies_are_read() {
        assert!(should_inspect_body(None, None));
        assert!(should_inspect_body(Some(0), None));
        assert!(should_inspect_body(Some(INSPECT_LIMIT), None));
        assert!(!should_inspect_body(Some(INSPECT_LIMIT + 1), None));
    }

    #[test]
    fn only_text_and_html_bodies_are_read() {
        assert!(should_inspect_body(None, Some("text/html; charset=UTF-8")));
        assert!(should_inspect_body(
            Some(15),
            Some("text/plain;charset=UTF-8")
        ));
        assert!(should_inspect_body(None, Some("Text/HTML")));
        assert!(!should_inspect_body(None, Some("application/json")));
        assert!(!should_inspect_body(None, Some("text/event-stream")));
        assert!(!should_inspect_body(
            Some(10),
            Some("application/problem+json")
        ));
        assert!(!should_inspect_body(
            Some(INSPECT_LIMIT + 1),
            Some("text/html")
        ));
    }
}
