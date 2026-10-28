/// Seconds a browser or crawler is asked to wait before trying again.
pub const RETRY_AFTER_SECONDS: u32 = 120;

/// The down page's headers, besides its status, 503. Never cached anywhere; it
/// loads nothing from anywhere (the styles and the picture are inline).
pub const DOWN_HEADERS: &[(&str, &str)] = &[
    ("content-type", "text/html; charset=utf-8"),
    ("retry-after", "120"),
    ("cache-control", "no-store"),
    ("x-robots-tag", "noindex"),
    ("x-content-type-options", "nosniff"),
    ("referrer-policy", "no-referrer"),
    (
        "content-security-policy",
        "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    ),
];

const TEMPLATE: &str = include_str!("page.html");

/// The site's name as the page shows it, from the request's host. Only these
/// fixed strings ever reach the page, never the host itself.
pub fn site_name(host: &str) -> &'static str {
    match host.to_ascii_lowercase().trim_end_matches('.') {
        "arbikullakshi.com" | "www.arbikullakshi.com" => "arbikullakshi.com",
        _ => "This site",
    }
}

/// The down page for a request to `host`.
pub fn render(host: &str) -> String {
    TEMPLATE.replace("{{site}}", site_name(host))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_each_public_site() {
        assert_eq!(site_name("arbikullakshi.com"), "arbikullakshi.com");
        assert_eq!(site_name("WWW.arbikullakshi.com."), "arbikullakshi.com");
        assert_eq!(site_name("hypernova.arbikullakshi.com"), "This site");
        assert_eq!(site_name("<script>alert(1)</script>"), "This site");
        assert_eq!(site_name(""), "This site");
    }

    #[test]
    fn the_page_is_self_contained() {
        let page = render("www.arbikullakshi.com");
        assert!(page.contains("<title>arbikullakshi.com is offline for a moment</title>"));
        assert!(!page.contains("{{"), "an unfilled placeholder");
        for external in [
            "http://", "https://", "//fonts", "@import", "url(", "<script", "<link", "src=",
        ] {
            assert!(
                !page.contains(external),
                "the page loads something: {external}"
            );
        }
    }

    #[test]
    fn retry_after_matches_the_header() {
        let header = DOWN_HEADERS
            .iter()
            .find(|(name, _)| *name == "retry-after")
            .map(|(_, value)| *value);
        assert_eq!(header, Some(RETRY_AFTER_SECONDS.to_string().as_str()));
    }

    #[test]
    fn the_page_is_never_cached() {
        assert!(DOWN_HEADERS.contains(&("cache-control", "no-store")));
    }
}
