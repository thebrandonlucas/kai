# Caddy, a web server that gets and renews its sites' HTTPS certificates
# itself, as a machine's service: its settings, their checks, and the
# model they fold into, which each backend renders.
Caddy :: [].{

	## Email is the address Caddy gives the certificate authority for its
	## account, at most once. Each Site serves a domain over HTTPS.
	Setting : [Email(Str), Site(Str, SiteTarget)]

	## Where a site's requests go: ReverseProxy to an upstream,
	## `host:port`, `[ipv6]:port` or `unix//path`, such as "localhost:8080",
	## or Files served from an absolute directory such as "/srv/files".
	SiteTarget : [ReverseProxy(Str), Files(Str)]

	## Caddy's settings, folded: the account's email ("" for none) and the
	## sites.
	Server : { email : Str, sites : List(Site) }

	Site : { domain : Str, target : SiteTarget }

	## The TCP ports Caddy serves: 80 for HTTP, which redirects to HTTPS and
	## answers the certificate authority's challenge, and 443 for HTTPS.
	tcp_ports : List(U16)
	tcp_ports = [80, 443]

	## The UDP port Caddy serves HTTP/3 on, beside HTTPS on TCP.
	udp_ports : List(U16)
	udp_ports = [443]

	## Caddy's settings folded; a later Email wins, and `problems` reports
	## it.
	server : List(Setting) -> Server
	server = |settings|
		settings.fold(
			{ email: "", sites: [] },
			|s, setting|
				match setting {
					Email(email) => { ..s, email }
					Site(domain, target) => { ..s, sites: s.sites.append({ domain, target }) }
				},
		)

	## What is wrong with Caddy's settings, checked as Kaifile.roc compiles.
	## Every value is checked rather than escaped, so none can add a
	## directive to the Caddyfile a backend renders.
	problems : List(Setting) -> List(Str)
	problems = |settings| {
		s = Caddy.server(settings)
		emails = settings.join_map(
			|setting|
				match setting {
					Email(email) => [email]
					Site(_, _) => []
				},
		)
		domains = s.sites.map(|site| site.domain)
		var $found = if (s.sites.is_empty()) ["Caddy needs at least one Site"] else []
		if emails.len() > 1 {
			$found = $found.append("Caddy's Email is given more than once")
		}
		for email in emails.drop_if(Caddy.valid_email) {
			$found = $found.append(
				"Caddy's Email \"${email}\" is no email address, such as "
					.concat("\"admin@example.com\""),
			)
		}
		for domain in domains {
			repeated = domains.keep_if(|d| d == domain).len() > 1
			if repeated and !$found.contains(Caddy.repeated_site(domain)) {
				$found = $found.append(Caddy.repeated_site(domain))
			}
		}
		for site in s.sites {
			domain = site.domain
			if domain.starts_with("*.") {
				$found = $found.append(Caddy.wildcard(domain))
			} else if !Caddy.valid_domain(domain) {
				$found = $found.append(
					"Caddy site \"${domain}\" is no domain name, such as \"example.com\"",
				)
			}
			match site.target {
				ReverseProxy(upstream) if !Caddy.valid_upstream(upstream) => {
					$found = $found.append(
						"Caddy site ${domain}: ReverseProxy \"${upstream}\" is no "
							.concat("upstream; use host:port, [ipv6]:port or unix//path"),
					)
				}
				Files(path) if !Caddy.valid_path(path) => {
					$found = $found.append(
						"Caddy site ${domain}: Files \"${path}\" is no absolute path of "
							.concat("letters, digits and /._-+@,"),
					)
				}
				_ => {}
			}
		}
		$found
	}

	repeated_site : Str -> Str
	repeated_site = |domain| "Caddy site ${domain} is declared more than once"

	## A lowercase DNS name, such as "example.com": no wildcard, scheme, port
	## or path.
	valid_domain : Str -> Bool
	valid_domain = |domain| Caddy.valid_host(domain)

	## Why wildcard site `domain` is refused: its certificate needs a DNS
	## challenge, which needs the DNS provider's credentials.
	wildcard : Str -> Str
	wildcard = |domain|
		"Caddy site \"${domain}\" is a wildcard, whose certificate needs a DNS "
			.concat("challenge kai does not set up; give each name its own Site")

	## A lowercase DNS name or an IPv4 address: labels of 1 to 63 of a-z,
	## 0-9 and `-`, neither starting nor ending with `-`, joined by `.`.
	valid_host : Str -> Bool
	valid_host = |host| {
		label_byte = |b| (b >= 'a' and b <= 'z') or Caddy.digit(b) or b == '-'
		valid_label = |label| {
			bytes = label.to_utf8()
			(bytes.len() >= 1 and bytes.len() <= 63)
				and bytes.first() != Ok('-')
				and bytes.last() != Ok('-')
				and bytes.all(label_byte)
		}
		host.count_utf8_bytes() <= 253 and host.split_on(".").all(valid_label)
	}

	## Where a reverse proxy sends requests: `host:port` for a lowercase name
	## or IPv4 address, such as "localhost:8080", `[ipv6]:port`, such as
	## "[::1]:8080", or `unix//path` for a Unix socket at an absolute path.
	valid_upstream : Str -> Bool
	valid_upstream = |upstream| {
		ipv6_byte = |b|
			Caddy.digit(b) or "abcdefABCDEF:".to_utf8().contains(b)
		if upstream.starts_with("unix//") {
			Caddy.valid_path(upstream.drop_prefix("unix/"))
		} else if upstream.starts_with("[") {
			match upstream.drop_prefix("[").split_first("]:") {
				Ok({ before, after }) =>
					!before.is_empty()
						and before.to_utf8().all(ipv6_byte)
						and Caddy.valid_port(after)
				Err(_) => Bool.False
			}
		} else {
			match upstream.split_first(":") {
				Ok({ before, after }) =>
					Caddy.valid_host(before) and Caddy.valid_port(after)
				Err(_) => Bool.False
			}
		}
	}

	## A port from 1 to 65535, in decimal digits.
	valid_port : Str -> Bool
	valid_port = |port|
		port.to_utf8().all(Caddy.digit)
			and match U16.from_str(port) {
				Ok(number) => number > 0
				Err(_) => Bool.False
			}

	## An absolute path of letters, digits and `/._-+@,`: no whitespace,
	## quote, brace or `#`, which the Caddyfile would read as syntax.
	valid_path : Str -> Bool
	valid_path = |path| {
		plain = |b|
			(b >= 'a' and b <= 'z')
				or (b >= 'A' and b <= 'Z')
				or Caddy.digit(b)
				or "/._-+@,".to_utf8().contains(b)
		path.starts_with("/") and path.to_utf8().all(plain)
	}

	## One plain address, `local@domain`: a local part of letters, digits and
	## `._+-`, and a lowercase domain name with at least two labels.
	valid_email : Str -> Bool
	valid_email = |email| {
		local_byte = |b|
			(b >= 'a' and b <= 'z')
				or (b >= 'A' and b <= 'Z')
				or Caddy.digit(b)
				or "._+-".to_utf8().contains(b)
		match email.split_first("@") {
			Ok({ before, after }) =>
				!before.is_empty()
					and before.count_utf8_bytes() <= 64
					and before.to_utf8().all(local_byte)
					and after.contains(".")
					and Caddy.valid_host(after)
			Err(_) => Bool.False
		}
	}

	digit : U8 -> Bool
	digit = |b| b >= '0' and b <= '9'
}

# Every value a site, upstream, path or email can take that the Caddyfile
# could read as more than one token, or as a block, is refused.
expect {
	domains = ["example.com", "localhost", "a-1.example.org"]
	not_domains = [
		"",
		"Example.com",
		"https://example.com",
		"example.com:443",
		"example.com/path",
		"-a.example.com",
		"a..com",
		"example.com.",
		"*.example.com",
		"*.*.example.com",
		"a.*.example.com",
		"example.com {",
		"example.com\nrespond hi",
	]
	upstreams = [
		"localhost:8080",
		"127.0.0.1:3000",
		"app.internal:443",
		"[::1]:8080",
		"unix//run/app/app.sock",
	]
	not_upstreams = [
		"localhost",
		"localhost:0",
		"localhost:65536",
		"localhost:80 {",
		"http://localhost:8080",
		"localhost:8080\nrespond hi",
		"[::1]",
		"[::1 x]:80",
		"unix/run/app.sock",
		"unix//run/app sock",
	]
	paths = ["/srv/files", "/var/www/example.com", "/srv/a_b-c+d@e,f"]
	not_paths = ["srv/files", "/srv/a b", "/srv/{path}", "/srv/#x", "/srv/\"x"]
	emails = ["admin@example.com", "first.last+tag@mail.example.org"]
	not_emails = ["", "admin", "@example.com", "a@localhost", "a b@example.com"]
	domains.all(Caddy.valid_domain)
		and !not_domains.any(Caddy.valid_domain)
		and upstreams.all(Caddy.valid_upstream)
		and !not_upstreams.any(Caddy.valid_upstream)
		and paths.all(Caddy.valid_path)
		and !not_paths.any(Caddy.valid_path)
		and emails.all(Caddy.valid_email)
		and !not_emails.any(Caddy.valid_email)
}

# Caddy without sites, an Email given twice, a domain served twice and
# values that are not what they claim are each refused.
expect {
	site = Site("example.com", ReverseProxy("localhost:8080"))
	checks = [
		([site], []),
		([Email("a@example.com"), site, Site("b.example.com", Files("/srv"))], []),
		([], ["Caddy needs at least one Site"]),
		([Email("admin@example.com")], ["Caddy needs at least one Site"]),
		(
			[Email("a@example.com"), Email("b@example.com"), site],
			["Caddy's Email is given more than once"],
		),
		(
			[site, Email("admin")],
			[
				"Caddy's Email \"admin\" is no email address, such as ".concat(
					"\"admin@example.com\"",
				),
			],
		),
		(
			[site, Site("example.com", Files("/srv")), site],
			["Caddy site example.com is declared more than once"],
		),
		(
			[Site("example.com:8443", ReverseProxy("localhost:8080"))],
			[
				"Caddy site \"example.com:8443\" is no domain name, "
					.concat("such as \"example.com\""),
			],
		),
		(
			[Site("*.example.com", ReverseProxy("localhost:8080"))],
			[Caddy.wildcard("*.example.com")],
		),
		(
			[Site("example.com", ReverseProxy("localhost"))],
			[
				"Caddy site example.com: ReverseProxy \"localhost\" is no upstream; "
					.concat("use host:port, [ipv6]:port or unix//path"),
			],
		),
		(
			[Site("example.com", Files("/srv/{x}"))],
			[
				"Caddy site example.com: Files \"/srv/{x}\" is no absolute path of "
					.concat("letters, digits and /._-+@,"),
			],
		),
	]
	checks.all(|(settings, expected)| Caddy.problems(settings) == expected)
}
