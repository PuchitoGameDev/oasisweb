# -*- coding: utf-8 -*-
"""Every page must carry the same footer as the home page, in its own language.

The site used to have four different footers. The thirteen static pages had the
home's, the blog and the glossary had a centred list of links, the legal pages had
their own four columns with different headings, and features.html and 404.html had
a bare nav and a one-line signature. Nothing failed, because a footer is not a
broken link: every one of them was valid, reachable, and inconsistent.

So this compares them instead of trusting them. For each built page it resolves
every href in the footer against that page's own address, strips the baseurl and
the language prefix, and requires the resulting set to be identical to the home
page's. The headings and the closing line are checked too, because a Spanish page
serving the English footer has the same links as the English one and would pass a
link-only comparison.

    python check_footers.py           # report and fail
"""
import io, itertools, os, re, sys, collections

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(ROOT, "_site")

# Written as escapes on purpose: these are compared literally, and a source file
# that has been through a shell pipeline can carry a mojibake accent that then
# silently stops matching.
HEADINGS = {
    "en": ["Product", "Resources", "Trust &amp; Community"],
    "es": ["Producto", "Recursos", "Confianza y comunidad"],
}
CLOSING = {
    "en": "no trackers on this page",
    "es": "sin rastreadores en esta p\u00e1gina",
}
TAGLINE = {
    "en": "Local workflows stay on your PC.",
    "es": "Los flujos de trabajo locales se quedan en tu PC.",
}
BASEURL = "/O.A.S.I.S."


def lang_of(rel):
    parts = rel.replace("\\", "/").split("/")
    return "es" if parts and parts[0] == "es" else "en"


def url_path(rel):
    """The address a built file is served at, e.g. es/blog/index.html -> /es/blog/."""
    parts = rel.replace("\\", "/").split("/")
    if parts[-1] == "index.html":
        return "/" + "/".join(parts[:-1]) + "/" if len(parts) > 1 else "/"
    return "/" + "/".join(parts)


def normalise(href, here):
    """A footer link reduced to something comparable across pages and languages."""
    if not href or href.startswith(("#", "mailto:", "javascript:")):
        return None
    if re.match(r"^https?://", href):
        return href  # external, identical everywhere
    frag = ""
    if "#" in href:
        href, frag = href.split("#", 1)
        frag = "#" + frag
    if href.startswith("/"):
        path = href
    else:
        base = here.rsplit("/", 1)[0] + "/"
        path = base + href
        # normalise ./ and ../ without touching the query string
        while "/./" in path:
            path = path.replace("/./", "/")
    # collapse index.html so a directory link and its file link compare equal
    if path.endswith("/index.html"):
        path = path[: -len("index.html")]
    if not path.endswith("/") and "." in path.rsplit("/", 1)[-1]:
        pass  # a file, keep it
    if BASEURL in path:
        path = path.split(BASEURL, 1)[1] or "/"
    if path.startswith("/es/"):
        path = path[3:]
    elif path == "/es":
        path = "/"
    return (path or "/") + frag


def footer_of(path):
    h = io.open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"<footer[\s\S]*?</footer>", h)
    return m.group(0) if m else None


def describe(foot, here):
    """A canonical form of the footer, in document order.

    Order matters and is kept: a footer whose links are the same set in a
    different order is still a different footer, and letting that pass is how
    the Trust column drifted with Security moved one slot up. Hrefs are resolved
    first, because the same footer is written once with relative links (the static
    pages, copied from the home) and once with absolute ones (the include, which
    has to work two directories down).
    """
    items = []
    for m in re.finditer(r'<a\b[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>', foot):
        n = normalise(m.group(1), here)
        if n:
            items.append(n + " :: " + re.sub(r"\s+", " ", strip_tags(m.group(2))).strip())
    heads = [re.sub(r"\s+", " ", h).strip() for h in re.findall(r'<h3 class="fth">(.*?)</h3>', foot, re.S)]
    text = re.sub(r"\s+", " ", strip_tags(foot)).strip()
    return items, heads, text


def strip_tags(s):
    s = re.sub(r"<[^>]+>", " ", s)
    for a, b in (("&amp;", "&"), ("&middot;", "·"), ("&nbsp;", " ")):
        s = s.replace(a, b)
    return s


def main():
    if not os.path.isdir(SITE):
        print("check_footers: no _site, run jekyll build first")
        return 1

    pages = []
    for dp, _d, fs in os.walk(SITE):
        for f in fs:
            if f.endswith(".html"):
                rel = os.path.relpath(os.path.join(dp, f), SITE)
                pages.append(rel)
    pages.sort()

    ref_en = rel_en = None
    ref_es = rel_es = None
    for rel in pages:
        if rel.replace("\\", "/") == "index.html":
            ref_en = rel
        if rel.replace("\\", "/") == "es/index.html":
            ref_es = rel

    if not ref_en or not ref_es:
        print("check_footers: no se encuentra la home EN o ES, que son la referencia")
        return 1

    base = {}
    for lang, ref in (("en", ref_en), ("es", ref_es)):
        items, heads, text = describe(footer_of(os.path.join(SITE, ref)), url_path(ref))
        base[lang] = (items, heads, text)

    problems = []
    stats = collections.Counter()
    for rel in pages:
        lang = lang_of(rel)
        foot = footer_of(os.path.join(SITE, rel))
        rels = rel.replace("\\", "/")
        if foot is None:
            problems.append("%s: no tiene <footer>" % rels)
            continue
        items, heads, text = describe(foot, url_path(rel))
        want_items, want_heads, want_text = base[lang]
        stats[lang] += 1

        if items != want_items:
            problems.append("%s: el pie no es el de la home %s" % (rels, lang))
            for a, b in itertools.zip_longest(want_items, items):
                if a != b:
                    problems.append("      home: " + str(a))
                    problems.append("      aqui: " + str(b))
                    break
        if heads != want_heads:
            problems.append("%s: las columnas del pie no son las de la home %s (%s)"
                            % (rels, lang, " / ".join(heads) or "ninguna"))
        # The wrapper class is what decides the styling, and nothing else catches
        # it: swapping class="foot" for the old class="foot-in" leaves the links,
        # the headings and the wording all correct while the page renders with a
        # bare one-line signature instead of the four columns.
        if 'class="foot"' not in foot:
            problems.append('%s: el pie no usa class="foot", asi que no hereda los estilos del pie real' % rels)
        for legacy in ('foot-in', 'blog-footer', 'firma'):
            if legacy in foot:
                problems.append("%s: el pie todavia usa la variante antigua %r" % (rels, legacy))
        for key, label in ((CLOSING[lang], "cierre"), (TAGLINE[lang], "descripcion")):
            if key not in text:
                problems.append("%s: el pie %s no dice %r" % (rels, label, key))
        # An English page must not be serving the Spanish footer, and vice versa.
        other = "es" if lang == "en" else "en"
        if CLOSING[other] in text and CLOSING[lang] not in text:
            problems.append("%s: parece servir el pie en %s" % (rels, other))

    print("check_footers: %d paginas EN, %d ES, pie de referencia con %d enlaces"
          % (stats["en"], stats["es"], len(base["en"][0])))
    if problems:
        print("check_footers: %d problema(s):" % len(problems))
        for p in problems:
            print("  x " + p)
        return 1
    print("check_footers: OK (todas las paginas comparten el pie de su home)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
