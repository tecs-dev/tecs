# markdown-title [![Build Status](https://travis-ci.org/phortuin/markdown-title.svg?branch=master)](https://travis-ci.org/phortuin/markdown-title)

> Parses title from Markdown-formatted text

## Install

```bash
$ npm install markdown-title
```

## Usage

```javascript
const markdownTitle = require('markdown-title')

let markdown = `
# Title
`

let title = markdownTitle(markdown) //=> Title
```

The first H1-level title that is found in your Markdown document will be returned, regardless of its position. Supports `pound`-style headers, not underlined headers (see [original Markdown docs](https://daringfireball.net/projects/markdown/syntax)). The reason is that I haven’t ever found an underlined header in the wild, and it’s much harder to parse:

```
This works:

# Title

This, too:

#     I can title? #

This doesn’t:

Title
=====
```

## License
[MIT](license) © [Anne Fortuin](https://phortuin.nl/)
