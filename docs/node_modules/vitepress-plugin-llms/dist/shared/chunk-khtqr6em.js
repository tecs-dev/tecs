// Built with bunup (https://bunup.dev)

// src/vitepress-components/utils.ts
var removeHtmlExtension = (pathSegment) => {
  const lastSlashIndex = pathSegment.lastIndexOf("/");
  const lastDotIndex = pathSegment.lastIndexOf(".");
  if (lastDotIndex > lastSlashIndex && lastDotIndex !== -1 && pathSegment.endsWith(".html")) {
    return pathSegment.slice(0, lastDotIndex);
  }
  return pathSegment;
};
function cleanUrl(url) {
  const { origin, pathname } = new URL(url);
  const pathnameWithoutTrailingSlash = pathname.replace(/\/+$/u, "");
  if (pathname.length > 0) {
    return origin + removeHtmlExtension(pathnameWithoutTrailingSlash);
  }
  return origin;
}
function resolveMarkdownPageURL(url) {
  const cleanedURL = cleanUrl(url);
  if (cleanedURL === globalThis.location.origin) {
    return `${cleanedURL}/index.md`;
  }
  return `${cleanedURL}.md`;
}
function downloadFile(filename, content, blobType = "text/plain") {
  const blob = content instanceof Blob ? content : new Blob([content], { type: blobType });
  const url = URL.createObjectURL(blob);
  Object.assign(document.createElement("a"), {
    download: filename,
    href: url
  }).click();
  URL.revokeObjectURL(url);
}

export { cleanUrl, resolveMarkdownPageURL, downloadFile };
