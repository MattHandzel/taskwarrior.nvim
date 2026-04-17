" Syntax highlighting for task.nvim rendered markdown.
" Inherits markdown and adds fieldname:value / +tag / priority / uuid rules.

if exists('b:current_syntax') && b:current_syntax ==# 'taskmd'
  finish
endif

runtime! syntax/markdown.vim
unlet! b:current_syntax

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
syntax match taskmdField /\<\w\+:\S\+/ containedin=ALL

" Priority values get their own highlight.
syntax match taskmdPriorityH /\<priority:H\>/
syntax match taskmdPriorityM /\<priority:M\>/
syntax match taskmdPriorityL /\<priority:L\>/

" Tags: +word (including hyphens).
syntax match taskmdTag /+\w[-_\w]*/

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
