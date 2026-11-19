#!/usr/bin/env python3
"""Survey pages of the Hentai Foundry source for design/hentaifoundry-adapter-plan.md.

    python3 scripts/hf-survey.py            # signed-out pass, then prompts for a login
    python3 scripts/hf-survey.py --no-login # signed-out pass only
    python3 scripts/hf-survey.py --login-only # signed-in pass only

Writes pages and a request log to design/hentaifoundry/survey/ (gitignored).
The password is read with no echo, sent only in the login POST and never
written anywhere. Cookie values are kept in memory only; the log records
cookie names. Nothing is posted except the login form and the signed-out
content filter: no faves, votes, comments or account settings are changed.
The session is logged out at the end.
"""
import getpass, hashlib, http.cookiejar, json, os, re, sys, time
import urllib.error, urllib.parse, urllib.request

BASE = "https://www.hentai-foundry.com"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/18.0 Safari/605.1.15")
OTHER_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:128.0) "
            "Gecko/20100101 Firefox/128.0")
STORY = "/stories/user/Someonewhosegod/19685/Autus"
CHAPTER = STORY + "/50410/Chapter-0/Experiment-Begins"
AUTHOR = "Someonewhosegod"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "design", "hentaifoundry", "survey")
GAP = 1.5


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Session:
    def __init__(self, log):
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar), NoRedirect)
        self.log = log

    def once(self, url, data=None, ua=UA, referer=None):
        headers = {"User-Agent": ua,
                   "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                   "Accept-Language": "en-US,en;q=0.9"}
        if referer:
            headers["Referer"] = referer
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        req = urllib.request.Request(url, data=body, headers=headers)
        try:
            resp = self.opener.open(req, timeout=40)
        except urllib.error.HTTPError as e:
            resp = e
        raw = resp.read()
        status = resp.getcode()
        head = resp.headers
        time.sleep(GAP)
        return status, head, raw

    def fetch(self, name, path, data=None, ua=UA, referer=None, secret=()):
        """Request `path`, following redirects by hand so every hop is logged.
        Saves the final body as `name`. Returns (status, text)."""
        url = path if path.startswith("http") else BASE + path
        method = "POST" if data is not None else "GET"
        for hop in range(6):
            status, head, raw = self.once(url, data, ua, referer)
            shown = url
            for s in secret:
                shown = shown.replace(urllib.parse.quote(s), "[redacted]")
            cookies = [c.split("=", 1)[0].strip() + " (" +
                       "; ".join(p.strip() for p in c.split(";")[1:]) + ")"
                       for c in head.get_all("Set-Cookie") or []]
            self.log.write(f"{name}: {method} {shown}\n    status {status}"
                           f" | type {head.get('Content-Type')} | {len(raw)} bytes\n")
            if data is not None:
                sent = {k: ("[redacted]" if "password" in k.lower() else
                            ("[token]" if "CSRF" in k else v)) for k, v in data.items()}
                self.log.write(f"    form {sent}\n")
            if head.get("Location"):
                self.log.write(f"    location {head.get('Location')}\n")
            for c in cookies:
                self.log.write(f"    set-cookie {c}\n")
            self.log.flush()
            if status in (301, 302, 303, 307, 308) and head.get("Location"):
                url = urllib.parse.urljoin(url, head.get("Location"))
                if status in (301, 302, 303):
                    data, method = None, "GET"
                continue
            break
        text = raw.decode("utf-8", errors="replace")
        ext = ".xml" if "xml" in (head.get("Content-Type") or "") else ".html"
        with open(os.path.join(OUT, name + ext), "w", encoding="utf-8") as f:
            f.write(text)
        print(f"  {name}: {status}, {len(raw)} bytes")
        return status, text

    def pass_bot_check(self, name, path):
        """Fetch `path`; if the proof-of-work page comes back, do the work
        and submit it. Returns the final (status, text)."""
        status, text = self.fetch(name, path)
        m = re.search(r'id="anubis_challenge"[^>]*>(.*?)</script>', text, re.S)
        if not m:
            return status, text
        info = json.loads(m.group(1))
        rules, ch = info["rules"], info["challenge"]
        self.log.write(f"    bot check: algorithm {rules.get('algorithm')}, difficulty {rules.get('difficulty')}\n")
        started, nonce, want = time.time(), 0, "0" * rules["difficulty"]
        while True:
            digest = hashlib.sha256((ch["randomData"] + str(nonce)).encode()).hexdigest()
            if digest.startswith(want):
                break
            nonce += 1
        ms = max(int((time.time() - started) * 1000), 350)
        self.log.write(f"    solved: nonce {nonce}\n")
        q = urllib.parse.urlencode({"id": ch["id"], "response": digest, "nonce": nonce,
                                    "redir": BASE + path, "elapsedTime": ms})
        return self.fetch(name + "-after-check",
                          "/.within.website/x/cmd/anubis/api/pass-challenge?" + q)


def token_of(text):
    m = (re.search(r'name="YII_CSRF_TOKEN"[^>]*value="([^"]+)"', text) or
         re.search(r'value="([^"]+)"[^>]*name="YII_CSRF_TOKEN"', text))
    return m.group(1) if m else None


def signed_out(log):
    print("Signed-out pass")
    s = Session(log)
    log.write("== A. signed out, fresh session ==\n")
    # A story link before the age step: redirect, age page, or the story?
    s.pass_bot_check("a01-deeplink-before-age", STORY)
    s.fetch("a02-enter", "/?enterAgree=1&size=1550")
    s.fetch("a03-deeplink-after-age", STORY)
    # Default content filters of a new session (the filter form in the page).
    status, text = s.fetch("a04-search-default-filters", "/search/stories?query=dragon&search_in=all")
    # Is the pass cookie tied to the User-Agent?
    s.fetch("a05-same-cookies-other-user-agent", "/site/about", ua=OTHER_UA)
    # Feeds, before and after showing everything.
    s.fetch("a06-feed-user-stories-default", f"/feed/userStories/username/{AUTHOR}")
    s.fetch("a07-feed-recent-stories-default", "/feed/RecentStories")
    token = token_of(text)
    if token:
        form = {"YII_CSRF_TOKEN": token, "filter_media": "A", "filter_order": "date_new", "filter_type": "0"}
        for k in ("nudity", "violence", "profanity", "racism", "sex", "spoilers"):
            form["rating_" + k] = "3"
        for k in ("yaoi", "yuri", "teen", "guro", "furry", "beast", "male", "female",
                  "futa", "other", "scat", "incest", "rape"):
            form["rating_" + k] = "1"
        s.fetch("a08-filters-show-all", "/site/filters", data=form, referer=BASE + "/search/stories")
    s.fetch("a09-feed-user-stories-all", f"/feed/userStories/username/{AUTHOR}")
    s.fetch("a10-feed-story-comments", "/feed/StoryComments/id/19685")
    s.fetch("a11-feed-category", "/feed/categoryStories/id/13")
    status, listing = s.fetch("a12-author-stories-all", f"/stories/user/{AUTHOR}")
    s.fetch("a13-author-stories-page-2", f"/stories/user/{AUTHOR}/page/2")
    # A one-chapter story, if the listing has one.
    single = None
    for row in listing.split('class="storyRow"')[1:]:
        if re.search(r"Chapters:</span>\s*1\s*<", row):
            m = re.search(r'href="(/stories/user/[^"]+)"', row)
            if m:
                single = m.group(1)
                break
    if single:
        s.fetch("a14-single-chapter-story", single)
    else:
        log.write("a14-single-chapter-story: none on the author's first page\n")
    s.fetch("a15-users-by-letter", "/users/byletter")
    s.fetch("a16-category-browse", "/category/browse")


def signed_in(log):
    print("\nSigned-in pass")
    username = input("Hentai Foundry username: ").strip()
    password = getpass.getpass("Password (not shown, not saved): ")
    if not username or not password:
        print("No credentials entered; skipping.")
        return
    s = Session(log)
    log.write("\n== B. signed in ==\n")
    s.pass_bot_check("b01-start", "/")
    s.fetch("b02-enter", "/?enterAgree=1&size=1550")
    status, page = s.fetch("b03-login-form", "/site/login")
    token = token_of(page)
    if not token:
        print("No login token found; see b03-login-form.html")
        return
    form = {"YII_CSRF_TOKEN": token, "LoginForm[username]": username,
            "LoginForm[password]": password, "LoginForm[rememberMe]": "1", "yt0": "Login"}
    status, after = s.fetch("b04-login-result", "/site/login", data=form,
                            referer=BASE + "/site/login", secret=(password,))
    del password, form
    if "/site/logout" not in after:
        log.write("    NOT SIGNED IN (no logout link in the page)\n")
        print("Login did not succeed; see b04-login-result.html")
        return
    log.write("    signed in\n")
    log.write("    cookies now held: " + ", ".join(sorted(c.name for c in s.jar)) + "\n")
    me = urllib.parse.quote(username)
    try:
        s.fetch("b05-home", "/")
        s.fetch("b06-story", STORY)            # fave control, vote, comment form
        s.fetch("b07-chapter", CHAPTER)        # chapter comment form
        s.fetch("b08-search", "/search/stories?query=dragon&search_in=all")  # account filter form
        s.fetch("b09-author-profile", f"/user/{AUTHOR}/profile")  # watch / fave-user control
        s.fetch("b10-author-stories", f"/stories/user/{AUTHOR}")
        s.fetch("b11-own-profile", f"/user/{me}/profile")
        s.fetch("b12-own-fave-stories", f"/user/{me}/faves/stories")
        s.fetch("b13-own-fave-users", f"/user/{me}/faves/users")
        s.fetch("b14-fave-users-recent-stories", f"/users/FaveUsersRecentStories?username={me}")
        s.fetch("b15-feed-fave-users-recent-stories", f"/feed/FaveUsersRecentStories/username/{me}")
    finally:
        s.fetch("b99-logout", "/site/logout")


def main():
    os.makedirs(OUT, exist_ok=True)
    login_only = "--login-only" in sys.argv
    # A login-only run keeps the signed-out log and writes its own.
    name = "log-signed-in.txt" if login_only else "log.txt"
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as log:
        log.write(time.strftime("survey %Y-%m-%d %H:%M:%S\n"))
        if not login_only:
            signed_out(log)
        if "--no-login" not in sys.argv:
            signed_in(log)
    print(f"\nDone. Results in {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
