#!/usr/bin/env python3
"""Помощник freeze-sub.sh: серверы подписки, переименование/отключение, перевод ссылок в конфиги Xray.

  sublinks.py list  RAW RULES        -> строки: номер␟ключ␟протокол␟новое имя␟выкл(0/1)  (разделитель \x1f)
  sublinks.py build RAW RULES OUT    -> копия подписки (тот же формат) без отключённых, с новыми именами
  sublinks.py json  RAW RULES        -> JSON-массив конфигов Xray (для склейки с подпиской клиента)

RAW — .txt (ссылки по строке) или .json (массив конфигов Xray).
RULES — {"rename": {ключ: новое имя}, "skip": [ключ, ...]}; ключ = исходное имя сервера
(для повторяющихся имён: «имя (2)», «имя (3)»…).
"""
import base64, json, sys, copy
from urllib.parse import urlsplit, parse_qs, unquote, quote


def warn(msg):
    print("  ! " + msg, file=sys.stderr)


def b64d(s):
    s = s.strip().replace("-", "+").replace("_", "/")
    s += "=" * (-len(s) % 4)
    return base64.b64decode(s).decode("utf-8", "replace")


# ---------------- чтение подписки ----------------
def load(raw):
    """-> (kind, items); items: список {'name', 'proto', 'data'} ; data — ссылка или конфиг"""
    with open(raw, encoding="utf-8") as f:
        text = f.read()
    if raw.endswith(".json"):
        arr = json.loads(text)
        if isinstance(arr, dict):
            arr = [arr]
        items = []
        for c in arr:
            proto = "?"
            for o in c.get("outbounds", []):
                if o.get("protocol") not in ("freedom", "blackhole", "dns"):
                    proto = o.get("protocol", "?"); break
            items.append({"name": c.get("remarks", "") or "без названия", "proto": proto, "data": c})
        return "json", items
    items = []
    for line in text.splitlines():
        line = line.strip()
        if "://" not in line or line.startswith("#"):
            continue
        items.append({"name": link_name(line), "proto": line.split("://", 1)[0].lower(), "data": line})
    return "txt", items


def link_name(link):
    if link.lower().startswith("vmess://"):
        try:
            return json.loads(b64d(link[8:])).get("ps", "") or "без названия"
        except Exception:
            return "vmess"
    if "#" in link:
        return unquote(link.rsplit("#", 1)[1]) or "без названия"
    return "без названия"


def with_keys(items):
    seen = {}
    for it in items:
        n = it["name"]
        seen[n] = seen.get(n, 0) + 1
        it["key"] = n if seen[n] == 1 else f"{n} ({seen[n]})"
    return items


def load_rules(path):
    try:
        with open(path, encoding="utf-8") as f:
            r = json.load(f)
    except Exception:
        r = {}
    return r.get("rename", {}) or {}, set(r.get("skip", []) or [])


def apply_rules(items, rules):
    ren, skip = rules
    out = []
    for it in items:
        if it["key"] in skip:
            continue
        it = dict(it)
        it["new"] = ren.get(it["key"], it["name"])
        out.append(it)
    return out


def rename_link(link, name):
    if link.lower().startswith("vmess://"):
        try:
            j = json.loads(b64d(link[8:]))
            j["ps"] = name
            return "vmess://" + base64.b64encode(json.dumps(j, ensure_ascii=False).encode()).decode()
        except Exception:
            return link
    base = link.rsplit("#", 1)[0] if "#" in link else link
    return base + "#" + quote(name, safe="")


# ---------------- ссылка -> outbound Xray ----------------
def q1(q, k, d=""):
    v = q.get(k)
    return v[0] if v else d


def stream(net, sec, q, host_default):
    net = (net or "tcp").lower()
    if net in ("raw",):
        net = "tcp"
    if net == "splithttp":
        net = "xhttp"
    st = {"network": net}
    path = q1(q, "path", "/") or "/"
    host = q1(q, "host")
    if net == "ws":
        st["wsSettings"] = {"path": path, **({"host": host} if host else {})}
    elif net == "grpc":
        st["grpcSettings"] = {"serviceName": q1(q, "serviceName", q1(q, "path", "")),
                              "multiMode": q1(q, "mode") == "multi"}
    elif net == "httpupgrade":
        st["httpupgradeSettings"] = {"path": path, **({"host": host} if host else {})}
    elif net == "xhttp":
        x = {"path": path, "mode": q1(q, "mode", "auto")}
        if host:
            x["host"] = host
        extra = q1(q, "extra")
        if extra:
            try:
                x["extra"] = json.loads(extra)
            except Exception:
                pass
        st["xhttpSettings"] = x
    elif net == "kcp":
        st["kcpSettings"] = {"header": {"type": q1(q, "headerType", "none")},
                             **({"seed": q1(q, "seed")} if q1(q, "seed") else {})}
    elif net == "tcp" and q1(q, "headerType") == "http":
        st["tcpSettings"] = {"header": {"type": "http", "request": {
            "path": [path], "headers": {"Host": [h for h in host.split(",") if h] or [host_default]}}}}
    elif net not in ("tcp",):
        raise ValueError(f"транспорт «{net}» не поддерживается")

    sec = (sec or "none").lower()
    sni = q1(q, "sni", q1(q, "peer", ""))
    fp = q1(q, "fp")
    alpn = [a for a in q1(q, "alpn").split(",") if a]
    if sec == "tls":
        t = {"serverName": sni or host or host_default}
        if fp:
            t["fingerprint"] = fp
        if alpn:
            t["alpn"] = alpn
        if q1(q, "allowInsecure") in ("1", "true") or q1(q, "insecure") in ("1", "true"):
            t["allowInsecure"] = True
        st["security"] = "tls"; st["tlsSettings"] = t
    elif sec == "reality":
        st["security"] = "reality"
        st["realitySettings"] = {"serverName": sni, "fingerprint": fp or "chrome",
                                 "publicKey": q1(q, "pbk"), "shortId": q1(q, "sid"),
                                 "spiderX": q1(q, "spx", "")}
    else:
        st["security"] = "none"
    return st


def to_outbound(link):
    scheme = link.split("://", 1)[0].lower()
    if scheme == "vmess":
        j = json.loads(b64d(link[8:].split("#")[0]))
        q = {"path": [j.get("path", "") or "/"], "host": [j.get("host", "")], "sni": [j.get("sni", "")],
             "fp": [j.get("fp", "")], "alpn": [j.get("alpn", "")], "headerType": [j.get("type", "")],
             "serviceName": [j.get("path", "")], "mode": [j.get("mode", "")]}
        sec = "tls" if j.get("tls") == "tls" else "none"
        host = j["add"]
        return {"tag": "proxy", "protocol": "vmess",
                "settings": {"vnext": [{"address": host, "port": int(j["port"]), "users": [{
                    "id": j["id"], "alterId": int(j.get("aid", 0) or 0),
                    "security": j.get("scy", "auto") or "auto"}]}]},
                "streamSettings": stream(j.get("net", "tcp"), sec, q, host)}

    u = urlsplit(link)
    q = parse_qs(u.query)
    host, port = u.hostname, u.port
    user = unquote(u.username or "")

    if scheme == "vless":
        usr = {"id": user, "encryption": q1(q, "encryption", "none") or "none"}
        if q1(q, "flow"):
            usr["flow"] = q1(q, "flow")
        return {"tag": "proxy", "protocol": "vless",
                "settings": {"vnext": [{"address": host, "port": port, "users": [usr]}]},
                "streamSettings": stream(q1(q, "type", "tcp"), q1(q, "security", "none"), q, host)}
    if scheme == "trojan":
        return {"tag": "proxy", "protocol": "trojan",
                "settings": {"servers": [{"address": host, "port": port, "password": user}]},
                "streamSettings": stream(q1(q, "type", "tcp"), q1(q, "security", "tls"), q, host)}
    if scheme == "ss":
        if q1(q, "plugin"):
            raise ValueError("shadowsocks с плагином не поддерживается")
        if u.password is not None:            # ss://method:pass@host:port
            method, pwd = unquote(u.username), unquote(u.password)
        elif "@" in link.split("://", 1)[1].split("#")[0]:   # ss://BASE64(method:pass)@host:port
            method, pwd = b64d(unquote(u.username)).split(":", 1)
        else:                                  # ss://BASE64(method:pass@host:port)
            body = b64d(link[5:].split("#")[0].split("?")[0])
            cred, hp = body.rsplit("@", 1)
            method, pwd = cred.split(":", 1)
            host, port = hp.rsplit(":", 1)[0].strip("[]"), int(hp.rsplit(":", 1)[1])
        return {"tag": "proxy", "protocol": "shadowsocks",
                "settings": {"servers": [{"address": host, "port": port, "method": method, "password": pwd}]}}
    if scheme in ("socks", "socks5"):
        srv = {"address": host, "port": port}
        if u.username:
            if u.password is not None:
                srv["users"] = [{"user": unquote(u.username), "pass": unquote(u.password)}]
            else:
                c = b64d(unquote(u.username))
                if ":" in c:
                    a, b = c.split(":", 1); srv["users"] = [{"user": a, "pass": b}]
        return {"tag": "proxy", "protocol": "socks", "settings": {"servers": [srv]}}
    raise ValueError(f"протокол «{scheme}» не поддерживается")


def to_config(link, name):
    ob = to_outbound(link)
    if ob["protocol"] == "socks":   # socks не везёт UDP через прокси надёжно — как в local.json
        rules = [{"type": "field", "network": "udp", "port": "443", "outboundTag": "block"}]
    else:
        rules = []
    return {
        "remarks": name,
        "log": {"loglevel": "warning"},
        "dns": {"servers": ["https://1.1.1.1/dns-query"]},
        "inbounds": [{"tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
                      "settings": {"udp": True},
                      "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}}],
        "outbounds": [ob, {"tag": "direct", "protocol": "freedom"},
                      {"tag": "block", "protocol": "blackhole"}],
        "routing": {"domainStrategy": "AsIs", "rules": rules},
    }


# ---------------- команды ----------------
def main():
    cmd, raw, rules = sys.argv[1], sys.argv[2], sys.argv[3]
    kind, items = load(raw)
    items = with_keys(items)
    r = load_rules(rules)

    if cmd == "list":
        ren, skip = r
        for i, it in enumerate(items, 1):
            print("\x1f".join([str(i), it["key"], it["proto"], ren.get(it["key"], ""), "1" if it["key"] in skip else "0"]))
        return

    kept = apply_rules(items, r)

    if cmd == "build":
        out = sys.argv[4]
        with open(out, "w", encoding="utf-8") as f:
            if kind == "json":
                arr = []
                for it in kept:
                    c = copy.deepcopy(it["data"]); c["remarks"] = it["new"]; arr.append(c)
                json.dump(arr, f, ensure_ascii=False, indent=1)
            else:
                for it in kept:
                    f.write((rename_link(it["data"], it["new"]) if it["new"] != it["name"] else it["data"]) + "\n")
        print(len(kept))
        return

    if cmd == "json":
        arr = []
        for it in kept:
            if kind == "json":
                c = copy.deepcopy(it["data"]); c["remarks"] = it["new"]; arr.append(c)
            else:
                try:
                    arr.append(to_config(it["data"], it["new"]))
                except Exception as e:
                    warn(f"«{it['new']}» пропущен: {e}")
        json.dump(arr, sys.stdout, ensure_ascii=False)
        return

    sys.exit("неизвестная команда")


if __name__ == "__main__":
    main()
