/*
 * Queue embedded frame resources that a page keeps in JSON or script data.
 *
 * Browsertrix normally follows an iframe after the browser has created it.
 * Some site builders (including Jimdo) keep the iframe URL in a serialized
 * page model and create the element only when the page is replayed.  In that
 * case replay would request a URL that the crawl never recorded.  This
 * behavior extracts the URL from the live DOM and from the serialized HTML,
 * then loads missing frame URLs in a hidden browser frame so Browsertrix
 * records the response and its subresources without adding a new crawl page.
 */

class CollectEmbeddedFrames {
  static id = "Collect Embedded Frames";
  static runInIframe = false;

  static init() {
    return { state: { found: 0, media: 0 } };
  }

  /* Browsertrix selects site-specific behaviors before the document has
   * finished loading.  The actual scan therefore happens in run(), after
   * the page model and its scripts are present. */
  static isMatch() {
    return true;
  }

  static normalize(value) {
    if (typeof value !== "string") {
      return "";
    }

    return value
      .replaceAll("\\/", "/")
      .replaceAll('\\"', '"')
      .replaceAll("&amp;", "&")
      .replaceAll("&#x2F;", "/")
      .replaceAll("&#47;", "/")
      .trim();
  }

  static mediaExtension = /\.(?:jpe?g|png|gif|webp|avif|svg|bmp|ico|mp3|wav|ogg|m4a|mp4|webm)(?:[?#]|$)/i;

  static resolveMedia(value, base) {
    const normalized = CollectEmbeddedFrames.normalize(value)
      .replace(/^url\(["']?/i, "")
      .replace(/["']?\)$/i, "")
      .trim();
    if (!normalized || normalized.startsWith("data:") || normalized.startsWith("blob:") || normalized.includes("${")) {
      return "";
    }
    try {
      const url = new URL(normalized, base || document.baseURI);
      if (!/^https?:$/i.test(url.protocol) || !CollectEmbeddedFrames.mediaExtension.test(url.pathname + url.search)) {
        return "";
      }
      return url.href;
    } catch (_) {
      return "";
    }
  }

  static mediaRefs(text, base) {
    const refs = new Set();
    if (typeof text !== "string" || !text) {
      return refs;
    }

    /* Static URLs in HTML, inline scripts, bundles, JSON models, and CSS. */
    const staticPattern = /(?:https?:\/\/|(?:\.{0,2}\/|\/))[^"'\\\s<>`]+?\.(?:jpe?g|png|gif|webp|avif|svg|bmp|ico|mp3|wav|ogg|m4a|mp4|webm)(?:[?#][^"'\\\s<>`]*)?/gi;
    let match;
    while ((match = staticPattern.exec(text)) !== null) {
      const url = CollectEmbeddedFrames.resolveMedia(match[0], base);
      if (url) {
        refs.add(url);
      }
    }

    /* A slideshow often keeps a URL factory in its JavaScript bundle, for
     * example `./slides/slide_${n.toString().padStart(3,"0")}.jpg`.
     * Enumerate only when the same source advertises a finite slide/page
     * range. This is generic and prevents an unbounded URL expansion. */
    const templatePattern = /((?:https?:\/\/|(?:\.{0,2}\/|\/))[^"'\\\s<>`]*\$\{[^}]+\}[^"'\\\s<>`]*\.(?:jpe?g|png|gif|webp|avif|svg|bmp|ico)(?:[?#][^"'\\\s<>`]*)?)/gi;
    const templates = [];
    while ((match = templatePattern.exec(text)) !== null) {
      templates.push(match[1]);
    }
    if (!templates.length) {
      return refs;
    }

    let maximum = 0;
    const rangePattern = /\b(?:endSlide|lastSlide|endPage|lastPage|slideCount|pageCount|totalSlides|totalPages|numberOfSlides|numberOfPages|numSlides|numPages|maxSlides|maxPages)\b\s*[:=]\s*(\d{1,4})/gi;
    while ((match = rangePattern.exec(text)) !== null) {
      maximum = Math.max(maximum, Number(match[1]));
    }
    maximum = Math.min(maximum, 1000);
    if (maximum < 1) {
      return refs;
    }

    for (const template of templates) {
      const expressions = Array.from(template.matchAll(/\$\{([^}]+)\}/g));
      for (let number = 1; number <= maximum; number += 1) {
        let value = template;
        for (const expression of expressions) {
          const widthMatch = expression[1].match(/padStart\(\s*(\d+)/i);
          const width = widthMatch ? Number(widthMatch[1]) : 0;
          const replacement = width > 0 ? String(number).padStart(width, "0") : String(number);
          value = value.replace(expression[0], replacement);
        }
        const url = CollectEmbeddedFrames.resolveMedia(value, base);
        if (url) {
          refs.add(url);
        }
      }
    }
    return refs;
  }

  static domMediaRefs() {
    const refs = new Set();
    if (typeof document === "undefined") {
      return refs;
    }
    const add = (value) => {
      const url = CollectEmbeddedFrames.resolveMedia(value, document.baseURI);
      if (url) {
        refs.add(url);
      }
    };
    const attributes = [
      "src", "data-src", "data-original", "data-lazy-src", "data-image",
      "data-background-image", "poster", "href", "srcset", "data-srcset",
    ];
    document.querySelectorAll("img,source,video,audio,object,link,[data-src],[data-original],[data-image],[data-background-image]").forEach((node) => {
      for (const attribute of attributes) {
        const value = node.getAttribute(attribute);
        if (!value) {
          continue;
        }
        if (attribute.includes("srcset")) {
          value.split(",").forEach((part) => add(part.trim().split(/\s+/)[0]));
        } else {
          add(value);
        }
      }
      const style = node.getAttribute("style");
      if (style) {
        const cssURL = /url\(([^)]+)\)/gi;
        let match;
        while ((match = cssURL.exec(style)) !== null) {
          add(match[1]);
        }
      }
    });
    return refs;
  }

  static candidate(value) {
    const normalized = CollectEmbeddedFrames.normalize(value);
    if (!/^https?:\/\//i.test(normalized)) {
      return "";
    }

    try {
      const url = new URL(normalized);
      const host = url.hostname.toLowerCase();
      const path = url.pathname.toLowerCase();
      const query = url.search.toLowerCase();

      /* A DOM iframe is already an explicit candidate.  URLs found in
       * serialized data are kept when their host/path identifies a frame or
       * common embedded media endpoint. */
      if (
        host === "iframe.jimcdn.com" ||
        host.startsWith("iframe.") ||
        host.startsWith("player.") ||
        path.includes("/iframe") ||
        path.includes("/embed") ||
        path.includes("/player") ||
        path.includes("/video/") ||
        query.includes("iframe")
      ) {
        return url.href;
      }
    } catch (_) {
      // Ignore malformed strings embedded in page data.
    }

    return "";
  }

  static isEmbeddedDocument() {
    if (typeof location === "undefined") {
      return false;
    }

    const host = location.hostname.toLowerCase();
    const path = location.pathname.toLowerCase();
    return (
      host === "iframe.jimcdn.com" ||
      host.startsWith("iframe.") ||
      host.startsWith("player.") ||
      path.includes("/iframe") ||
      path.includes("/embed")
    );
  }

  static findUrls() {
    const urls = new Set();
    const add = (value) => {
      const candidate = CollectEmbeddedFrames.candidate(value);
      if (candidate) {
        urls.add(candidate);
      }
    };

    /* Do not recursively inspect an embedded document.  Its normal browser
     * requests are still recorded, while scanning it for more frame URLs
     * would turn a single embed into an unbounded crawl tree. */
    if (typeof document !== "undefined" && !CollectEmbeddedFrames.isEmbeddedDocument()) {
      document.querySelectorAll("iframe[src], frame[src], embed[src]").forEach((node) => {
        add(node.src || node.getAttribute("src"));
      });

      const html = document.documentElement?.outerHTML || "";
      const decoded = CollectEmbeddedFrames.normalize(html);

      /* Explicit markup, including escaped markup in JSON page models. */
      const markup = /<(?:iframe|frame|embed)\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']/gi;
      let match;
      while ((match = markup.exec(decoded)) !== null) {
        add(match[1]);
      }

      /* Serialized builders often retain the URL without retaining an
       * <iframe> tag.  Extract URLs and keep only frame/media endpoints. */
      const urlsInData = /https?:\\?\/\\?\/[^"'\\\s<>]+/gi;
      while ((match = urlsInData.exec(decoded)) !== null) {
        add(match[0]);
      }
    }

    return Array.from(urls);
  }

  async *run(ctx) {
    const { getState, sleep } = ctx.Lib;
    /* Give SPA frameworks a short window to render their initial slide and
     * expose script tags before scanning deferred resources. */
    await sleep(500);
    const found = new Set(CollectEmbeddedFrames.findUrls());
    ctx.state.found = found.size;
    const existing = new Set();
    if (typeof document !== "undefined") {
      document.querySelectorAll("iframe[src], frame[src], embed[src]").forEach((node) => {
        try {
          existing.add(new URL(node.src || node.getAttribute("src"), location.href).href);
        } catch (_) {
          // Ignore malformed or non-HTTP frame values.
        }
      });
    }

    /* A serialized page model can contain an iframe which is not inserted in
     * the DOM until a user opens a gallery or a video.  Request that resource
     * in a hidden browser frame so the recorder writes its response and its
     * normal subresources to the WARC.  It is deliberately not passed to
     * addLink(): doing that would make an embedded YouTube channel a new
     * crawl seed and could recursively enumerate its videos. */
    const captureTarget = document.body || document.documentElement;
    let requested = 0;
    if (captureTarget) {
      for (const url of found) {
        if (existing.has(url)) {
          continue;
        }
        const frame = document.createElement("iframe");
        frame.src = url;
        frame.setAttribute("aria-hidden", "true");
        frame.setAttribute("tabindex", "-1");
        frame.style.cssText =
          "position:absolute;left:-10000px;top:-10000px;width:1px;height:1px;border:0;opacity:0;pointer-events:none;";
        captureTarget.appendChild(frame);
        requested += 1;
        await sleep(1500);
        frame.remove();
        yield getState(ctx, `Embedded resource requested: ${url}`);
      }
    }

    /* Full-page captures must include resources which are only requested
     * after a user advances a gallery or slideshow.  Read inline scripts and
     * same-origin bundles, extract ordinary media URLs and finite URL
     * templates, then let the browser request them as hidden images/audio.
     * The recorder sees these as normal page resources; no replay-only code
     * or synthetic page links are introduced. */
    const media = CollectEmbeddedFrames.domMediaRefs();
    if (typeof document !== "undefined" && !CollectEmbeddedFrames.isEmbeddedDocument()) {
      const html = document.documentElement?.outerHTML || "";
      for (const url of CollectEmbeddedFrames.mediaRefs(html, document.baseURI)) {
        media.add(url);
      }
      const scripts = Array.from(document.scripts || []);
      for (const script of scripts) {
        if (script.textContent) {
          for (const url of CollectEmbeddedFrames.mediaRefs(script.textContent, document.baseURI)) {
            media.add(url);
          }
        }
        const source = script.src;
        if (!source) {
          continue;
        }
        try {
          const scriptURL = new URL(source, document.baseURI);
          if (scriptURL.origin !== location.origin) {
            continue;
          }
          const response = await fetch(scriptURL.href, { credentials: "include" });
          if (!response.ok) {
            continue;
          }
          const sourceText = await response.text();
          /* URL factories in bundled code normally resolve relative to the
           * document, so document.baseURI is intentionally used here. */
          for (const url of CollectEmbeddedFrames.mediaRefs(sourceText, document.baseURI)) {
            media.add(url);
          }
        } catch (_) {
          // A script may be opaque or unavailable; normal page requests stay recorded.
        }
      }
    }
    ctx.state.media = media.size;
    let mediaRequested = 0;
    if (captureTarget && media.size) {
      yield getState(ctx, `Deferred media planned: ${media.size}`);
      for (const url of media) {
        const element = /\.(?:mp3|wav|ogg|m4a)(?:[?#]|$)/i.test(url)
          ? document.createElement("audio")
          : /\.(?:mp4|webm)(?:[?#]|$)/i.test(url)
            ? document.createElement("video")
            : document.createElement("img");
        element.src = url;
        element.setAttribute("data-offlinebrowser-deferred-media", "true");
        element.setAttribute("aria-hidden", "true");
        element.setAttribute("alt", "");
        element.setAttribute("preload", "auto");
        element.style.cssText =
          "position:absolute;left:-10000px;top:-10000px;width:1px;height:1px;border:0;opacity:0;pointer-events:none;";
        captureTarget.appendChild(element);
        mediaRequested += 1;
      }
      /* Requests are concurrent; waiting once avoids a minute-long delay for
       * a few hundred slideshow frames while still giving the recorder time
       * to receive their responses. */
      await sleep(Math.min(10000, Math.max(2000, Math.ceil(mediaRequested / 20) * 250)));
      document.querySelectorAll('[data-offlinebrowser-deferred-media="true"]').forEach((node) => node.remove());
      yield getState(ctx, `Deferred media requested: ${mediaRequested} of ${media.size}`);
    }

    /* Keep the normal crawler behavior useful for lazy content.  This is a
     * small, bounded scroll pass rather than a site-specific page rewrite. */
    let stable = 0;
    let previousHeight = 0;
    for (let attempt = 0; attempt < 20 && stable < 3; attempt += 1) {
      const height = Math.max(
        document.body?.scrollHeight || 0,
        document.documentElement?.scrollHeight || 0,
      );
      window.scrollTo(0, height);
      await sleep(250);
      const nextHeight = Math.max(
        document.body?.scrollHeight || 0,
        document.documentElement?.scrollHeight || 0,
      );
      stable = nextHeight <= previousHeight ? stable + 1 : 0;
      previousHeight = nextHeight;
    }
    window.scrollTo(0, 0);

    ctx.state.found = found.size;
    yield getState(ctx, `Embedded resources requested: ${requested} of ${found.size}; media requested: ${mediaRequested} of ${media.size}`);
  }
}
