const markdownTitle = markdown => {
	let matches = markdown.match(/^#[^#][\s]*(.+?)#*?$/m)
	if (matches && matches.length) {
		return matches.pop().trim()
	}
	return
}

module.exports = markdownTitle
