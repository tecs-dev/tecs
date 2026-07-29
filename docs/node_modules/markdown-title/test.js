const test = require('tape')
const markdownTitle = require('./')

let earlyTitle = `
# Title

Some text!

# Another H1, who does this?
`

let lateTitle = `
I want to write an intro first

# Title comes late

Then more text
`

let manySpaces = `
#       Title prefixed with lots of space
`

let closingPound = `
# Title with closing pound mark #
`

let poundMarksInside = `
# Title with pound marks ## inside
`

let superMessyTitle = `
Let’s make it a bit harder

## Not getting props for a11y either

#        Title is kind # of messy but still valid         ####

See?
`

let textOnly = `
I only wrote text

## And possibly a H2
`

let noTextAtAll = ``

test('Finds titles', t => {
	t.plan(6)
	t.equal(markdownTitle(earlyTitle), 'Title')
	t.equal(markdownTitle(lateTitle), 'Title comes late')
	t.equal(markdownTitle(manySpaces), 'Title prefixed with lots of space')
	t.equal(markdownTitle(closingPound), 'Title with closing pound mark')
	t.equal(markdownTitle(poundMarksInside), 'Title with pound marks ## inside')
	t.equal(markdownTitle(superMessyTitle), 'Title is kind # of messy but still valid')
})

test('Doesn’t find titles', t => {
	t.plan(2)
	t.false(markdownTitle(textOnly))
	t.false(markdownTitle(noTextAtAll))
})
