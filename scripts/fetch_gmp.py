"""Fetch current IPO list + GMP from ipopremium.in and write gmp.json.

Run by .github/workflows/gmp.yml on a schedule. Uses only the standard library.
If the site does not return the data (blocked, layout change), the script exits
non-zero and the previous gmp.json is left untouched.
"""
import datetime as dt
import html
import http.cookiejar
import json
import re
import sys
import time
import urllib.parse
import urllib.request

HOME = "https://www.ipopremium.in/"
OUT = "gmp.json"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
MONTHS = {m: i for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1)}

opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def get(url, **headers):
    req = urllib.request.Request(url, headers={"User-Agent": UA, **headers})
    with opener.open(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def text(s):
    return html.unescape(re.sub(r"<[^>]+>", " ", s or "")).strip()


def num(s):
    m = re.search(r"-?[\d,]*\.?\d+", (s or "").replace(",", ""))
    return float(m.group()) if m else 0.0


def mdate(s, ref):
    """'Nov 5' -> ISO date, using the year of ref (close date), rolling over Dec->Jan."""
    m = re.match(r"\s*([A-Z][a-z]{2})\s+(\d{1,2})", s or "")
    if not m or not ref:
        return ""
    d = dt.date(ref.year, MONTHS[m.group(1)], int(m.group(2)))
    if (d - ref).days > 180:
        d = d.replace(year=d.year - 1)
    elif (ref - d).days > 180:
        d = d.replace(year=d.year + 1)
    return d.isoformat()


def qib_details(url):
    """QIB subscription (x), net QIB offered (Rs Cr) and MF demand (Rs Cr) from the IPO page's
    'Subscription Demand (in Rs crore)' table. Returns {} when the table is not there yet."""
    try:
        page = get(url)
    except Exception as e:  # one bad page should not sink the whole run
        print(f"skip {url}: {e}")
        return {}
    out = {}
    # fallback for max QIB bid: 'Total' offered shares in 'Subscription Details (No. of Shares)'
    # = net issue excl. anchor & market maker (matches the exchange figure for SME issues)
    j = page.find("Subscription Details")
    if j >= 0:
        for tr in re.findall(r"<tr[^>]*>(.*?)</tr>", page[j:page.find("</table>", j)], re.S):
            cells = [text(c) for c in re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)]
            if len(cells) >= 2 and cells[0].strip().upper() == "TOTAL" and cells[1] not in ("", "-"):
                out["totalOfferedSh"] = int(num(cells[1]))
    i = page.find("Subscription Demand")
    if i < 0:
        return out
    table = page[i:page.find("</table>", i)]
    rows = {}
    for tr in re.findall(r"<tr[^>]*>(.*?)</tr>", table, re.S):
        cells = [text(c) for c in re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)]
        if len(cells) >= 4:
            label = cells[0].upper().strip()
            # pages label rows either "QIB"/"MF" or "QIBs"/"Mutual funds"
            label = {"QIBS": "QIB", "MUTUAL FUNDS": "MF", "MUTUAL FUND": "MF"}.get(label, label)
            rows.setdefault(label, cells)
    if "QIB" in rows:
        _, offered, _, times = rows["QIB"][:4]
        if times not in ("", "-"):
            out["subs"] = num(times)
        if offered not in ("", "-"):
            out["qibCr"] = num(offered)
    if "MF" in rows and rows["MF"][2] not in ("", "-"):
        out["mfCr"] = num(rows["MF"][2])
    return out


def main():
    page = get(HOME)
    m = re.search(r'ajax:\s*\{\s*url:\s*"([^"]+)"', page)
    if not m:
        sys.exit("ipo data URL not found on page (blocked or layout changed)")
    base = json.loads('"' + m.group(1) + '"')
    hdr = {"X-Requested-With": "XMLHttpRequest", "Accept": "application/json", "Referer": HOME}
    # the default list (open + recent) and the site's own "Upcoming" filter, merged by IPO id
    upcoming = {"all": "true", "eq": "false", "sme": "false", "all_ipos": "false",
                "upcoming_ipos": "true", "open_ipos": "false", "closed_ipos": "false"}
    rows = {}
    for extra in ({}, upcoming):
        url = base + "&" + urllib.parse.urlencode({"draw": 1, "start": 0, "length": 60, **extra})
        for d in json.loads(get(url, **hdr)).get("data", []):
            rows.setdefault(d.get("id"), d)
    print(f"{len(rows)} rows, statuses: {sorted({d.get('current_status') for d in rows.values()})}")

    ipos = []
    for d in rows.values():
        if "Listed" in (d.get("open") or ""):
            continue
        try:
            close = dt.datetime.strptime(d.get("close") or "", "%b %d, %Y").date()
        except ValueError:
            close = None
        name_html = d.get("name") or ""
        chip = re.search(r'ip-chip">([^<]+)<', name_html)
        prem = d.get("premium") or ""
        gmp = num(text(prem).split()[0] if text(prem) else "")
        price_hi = float(d.get("max_price") or 0)
        link = re.search(r'href="([^"]+/view/ipo/[^"]+)"', name_html)
        detail = qib_details(html.unescape(link.group(1))) if link else {}
        time.sleep(1)
        ipos.append({
            "src": d.get("id"),
            "name": text(re.sub(r'<span class="hm-name__chips">.*', "", name_html)),
            "exch": chip.group(1).strip() if chip else d.get("type", ""),
            "status": d.get("current_status", ""),
            "priceLow": float(d.get("min_price") or 0) or price_hi,
            "priceHigh": price_hi,
            "lot": int(num(str(d.get("lot_size")))),
            "gmp": gmp,
            "gmpPct": round(gmp / price_hi * 100, 2) if price_hi else 0,
            "issueCr": num(d.get("issue_size")),
            "open": mdate(text(d.get("open")).split("–")[0], close),
            "close": close.isoformat() if close else "",
            "allot": mdate(d.get("allotment_date"), close),
            "listing": mdate(d.get("listing_date"), close),
            "subs": detail.get("subs", 0),
            "qibCr": detail.get("qibCr", ""),
            "mfCr": detail.get("mfCr", ""),
        })
        # max QIB bid quantity estimate; exact NSE figures come from exchange.json (scripts/fetch_exchange.ps1)
        if detail.get("totalOfferedSh"):
            ipos[-1].update(maxQibSh=detail["totalOfferedSh"], maxQibSrc="ipopremium (estimate)")
    if not ipos:
        sys.exit("no current IPOs parsed; keeping previous gmp.json")
    out = {"source": HOME, "updated": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"), "ipos": ipos}
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print(f"wrote {len(ipos)} IPOs")


if __name__ == "__main__":
    main()
