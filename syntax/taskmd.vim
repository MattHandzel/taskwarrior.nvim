" Syntax highlighting for taskwarrior.nvim rendered markdown.
" Inherits markdown and adds fieldname:value / +tag / priority / uuid rules.

if exists('b:current_syntax') && b:current_syntax ==# 'taskmd'
  finish
endif

runtime! syntax/markdown.vim
unlet! b:current_syntax

" Task descriptions may contain literal ``` (e.g. ASCII art, code examples, or
" quoted prose with backticks). Markdown's fenced-code-block regions would open
" on the first ``` and never close, painting every subsequent task line as
" code. Clear those regions so task lines stay line-scoped.
silent! syntax clear markdownCode
silent! syntax clear markdownCodeBlock
silent! syntax clear markdownCodeDelimiter
silent! syntax clear markdownHighlight
silent! syntax clear markdownFencedCodeBlock

" Header comment (filter / sort / rendered_at).
syntax match taskmdHeader /^<!--\s*taskmd\s.*-->$/ containedin=ALL

" Group section headers (## Project or ## +tag).
syntax match taskmdGroupHeader /^##\s.\+$/ containedin=ALL

" Checkbox prefixes.
syntax match taskmdCheckboxPending /^-\s\[\s\]/
syntax match taskmdCheckboxDone    /^-\s\[[xX]\]/
syntax match taskmdCheckboxActive  /^-\s\[>\]/

" field:value — project:, priority:, due:, scheduled:, recur:, wait:, until:,
" effort:, depends:, and any user-defined UDA of the same form.
syntax match taskmdField /\<\w\+:\S\+/

" Priority values get their own highlight. Defined AFTER taskmdField so
" vim's later-match-wins-at-equal-start rule picks these specific ones.
syntax match taskmdPriorityH /\<priority:H\>/
syntax match taskmdPriorityM /\<priority:M\>/
syntax match taskmdPriorityL /\<priority:L\>/

" Tags: +word (including hyphens). Requires a non-word char (or line start)
" immediately before the `+` so that `housing+food` doesn't paint `+food`
" as a tag. `\zs` records the match start *after* the prefix, so only the
" `+word` portion is highlighted.
syntax match taskmdTag /\%(^\|[^0-9A-Za-z_]\)\zs+\w[-_\w]*/

" UUID comment at EOL.
syntax match taskmdUuid /<!--\s*uuid:[0-9a-fA-F]\+\s*-->/ conceal

highlight default link taskmdHeader        Comment
highlight default link taskmdGroupHeader   Title
highlight default link taskmdCheckboxPending Statement
highlight default link taskmdCheckboxDone    Comment
highlight default link taskmdCheckboxActive  Special
highlight default link taskmdField         Identifier
highlight default link taskmdPriorityH     ErrorMsg
highlight default link taskmdPriorityM     WarningMsg
highlight default link taskmdPriorityL     Comment
highlight default link taskmdTag           Type
highlight default link taskmdUuid          Conceal

let b:current_syntax = 'taskmd'
