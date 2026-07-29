/**
* Cleans a given URL by removing its file extension from the pathname, if present.
*
* This function parses the input URL, removes the file extension from the last path segment if it exists
* (i.e., if the last dot comes after the last slash), and trims any trailing slash (except for the root
* path). The returned URL excludes query parameters and hash fragments.
*
* @example
* 	cleanUrl('https://example.com/docs/page.md') // 'https://example.com/docs/page'
* 	cleanUrl('https://example.com/docs/') // 'https://example.com/docs'
* 	cleanUrl('https://example.com/docs/page.md?query=1') // 'https://example.com/docs/page'
*
* @param url - The full URL string to clean.
* @returns The cleaned URL string with the file extension removed from the pathname.
*/
declare function cleanUrl(url: string): string;
declare function resolveMarkdownPageURL(url: string): string;
/**
* Triggers a file download in the browser with the specified filename and content.
*
* @example
* 	downloadFile('hello.txt', 'Hello, world!')
*
* @param filename - The name for the downloaded file (e.g., 'report.txt').
* @param content - The content of the file. Can be a string or other Blob-compatible data.
* @param blobType - The MIME type of the content (e.g., 'text/plain', 'application/json').
*/
declare function downloadFile(filename: string, content: Readonly<string | Blob>, blobType?: string): void;
export { resolveMarkdownPageURL, downloadFile, cleanUrl };
