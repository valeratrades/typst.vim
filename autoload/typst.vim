let s:JobStart = function(has('nvim') ? 'jobstart' : 'job_start')
let s:JobStop  = function(has('nvim') ? 'jobstop'  : 'job_stop')

augroup TypstWatchEmu
    autocmd!
augroup END

function! typst#TypstWatch(...) abort
    let l:src = expand('%:p')
    if empty(l:src) | echoerr 'TypstWatch: buffer has no file' | return | endif
    let l:out = s:OutputPath(l:src)              " '' when output_to_tmp is off
    if &filetype ==# 'typst'
        let l:plan = s:TypstPlan(a:000, l:src, l:out)
    elseif &filetype ==# 'markdown'
        let l:plan = s:PandocPlan(a:000, l:src, l:out)
    else
        echoerr 'TypstWatch: unsupported filetype ' . &filetype | return
    endif
    call s:StartWatch(l:plan)
endfunction

function! s:OutputPath(src) abort
    if !g:typst_output_to_tmp | return '' | endif
    let l:home = expand('$HOME')
    let l:rel = a:src =~# '^' . l:home
            \ ? substitute(a:src, '^' . l:home . '/', '', '')
            \ : a:src
    let l:rel = substitute(l:rel, '\.\(typ\|typst\|md\|markdown\)$', '', '')
    let l:out = '/tmp/typst_out/' . l:rel . '.pdf'
    call mkdir(fnamemodify(l:out, ':h'), 'p')
    return l:out
endfunction

function! s:TypstPlan(args, src, out) abort
    let l:argv = [g:typst_cmd, 'watch'] + a:args + ['--diagnostic-format', 'short']
    if g:typst_html | let l:argv += ['--features', 'html'] | endif
    let l:argv += ["'" . a:src . "'"]
    if !empty(a:out) | let l:argv += ['"' . a:out . '"'] | endif
    let l:argv += empty(g:typst_pdf_viewer) ? ['--open'] : ['--open', g:typst_pdf_viewer]
    return {'argv': l:argv, 'native': v:true, 'out': a:out}
endfunction

function! s:PandocPlan(args, src, out) abort
    " pandoc has no default file output -> always need an explicit -o target.
    let l:out = empty(a:out) ? expand('%:p:r') . '.pdf' : a:out
    let l:argv = [g:typst_pandoc_cmd] + a:args + ["'" . a:src . "'", '-o', '"' . l:out . '"']
    return {'argv': l:argv, 'native': v:false, 'out': l:out}
endfunction

function! s:JobOpts() abort
    return has('nvim')
        \ ? {'on_stderr': 'typst#TypstWatcherCb'}
        \ : {'err_mode': 'raw', 'err_cb': 'typst#TypstWatcherCb'}
endfunction

function! s:Wrap(argv) abort
    let l:cmd = join(a:argv)
    return has('win32') ? 'cmd /s /c "' . l:cmd . '"' : 'sh -c "' . l:cmd . '"'
endfunction

function! s:StopWatch() abort
    if exists('b:typst_watcher')
        try | call s:JobStop(b:typst_watcher) | catch | endtry
        unlet b:typst_watcher
    endif
    autocmd! TypstWatchEmu * <buffer>
endfunction

function! s:RunOnce(plan) abort         " transient one-shot; NOT stored in b:typst_watcher
    call s:JobStart(s:Wrap(a:plan.argv), s:JobOpts())
endfunction

function! s:OpenViewer(out) abort
    let l:viewer = !empty(g:typst_pdf_viewer) ? g:typst_pdf_viewer
                \ : has('win32') ? 'start' : has('mac') ? 'open' : 'xdg-open'
    call s:JobStart(s:Wrap([l:viewer, '"' . a:out . '"']), {})
endfunction

function! s:StartWatch(plan) abort
    call s:StopWatch()
    if a:plan.native
        let b:typst_watcher = s:JobStart(s:Wrap(a:plan.argv), s:JobOpts())
    else
        call s:RunOnce(a:plan)          " compile now
        call s:OpenViewer(a:plan.out)   " launch viewer once
        execute printf('autocmd TypstWatchEmu BufWritePost <buffer=%d> call s:RunOnce(%s)',
                     \ bufnr('%'), string(a:plan))
    endif
    echo 'Typst watch started'
endfunction

" Callback function for job exit
function! typst#TypstWatcherCb(channel, content, ...)
    let l:errors = []
    let l:lines = a:content
    if !has('nvim')
	let l:lines = split(l:lines, "\n")
    endif
    for l:line in l:lines
        " Probably this match can be done using errorformat.
	" Maybe do something like vim-dispatch.
        let l:match = matchlist(l:line, '\v^([^:]+):(\d+):(\d+):\s*(.+)$')
        if 0 < len(l:match)
            let l:error = {'filename': l:match[1],
                          \'lnum': l:match[2],
                          \'col': l:match[3],
                          \'text': l:match[4]}
            call add(l:errors, l:error)
        endif
    endfor
    call setqflist(l:errors)
    if g:typst_auto_open_quickfix
        execute empty(l:errors) ? 'cclose' : 'copen | wincmd p'
    endif
endfunction

" Below are adapted from preservim/vim-markdown
" They have their own MIT License at https://github.com/preservim/vim-markdown#license
let s:headersRegexp = '^='

" For each level, contains the regexp that matches at that level only.
"
let s:levelRegexpDict = {
    \ 1: '^=[^=]',
    \ 2: '^==[^=]',
    \ 3: '^===[^=]',
    \ 4: '^====[^=]',
    \ 5: '^=====[^=]',
    \ 6: '^======[^=]'
\ }


" Returns the level of the header at the given line.
"
" If there is no header at the given line, returns `0`.
"
function! s:GetLevelOfHeaderAtLine(linenum)
    let l:lines = join(getline(a:linenum, a:linenum + 1), "\n")
    for l:key in keys(s:levelRegexpDict)
        if l:lines =~ get(s:levelRegexpDict, l:key)
            return l:key
        endif
    endfor
    return 0
endfunction

function! s:GetHeaderLineNum(...)
    if a:0 == 0
        let l:l = line('.')
    else
        let l:l = a:1
    endif
    while(l:l > 0)
        if join(getline(l:l, l:l + 1), "\n") =~ s:headersRegexp
            return l:l
        endif
        let l:l -= 1
    endwhile
    return 0
endfunction

function! s:GetHeaderLevel(...)
    if a:0 == 0
        let l:line = line('.')
    else
        let l:line = a:1
    endif
    let l:linenum = s:GetHeaderLineNum(l:line)
    if l:linenum !=# 0
        return s:GetLevelOfHeaderAtLine(l:linenum)
    else
        return 0
    endif
endfunction

function! s:GetHeaderList()
    let l:bufnr = bufnr('%')
    let l:fenced_block = 0
    let l:front_matter = 0
    let l:header_list = []
    let l:vim_markdown_frontmatter = get(g:, 'vim_markdown_frontmatter', 0)
    for i in range(1, line('$'))
        let l:lineraw = getline(i)
        let l:l1 = getline(i+1)
        let l:line = substitute(l:lineraw, '#', "\\\#", 'g')
        if join(getline(i, i + 1), "\n") =~# s:headersRegexp && l:line =~# '^\S'
            let l:is_header = 1
        else
            let l:is_header = 0
        endif
        if l:is_header ==# 1 && l:fenced_block ==# 0 && l:front_matter ==# 0
            if match(l:line, '^#') > -1
                let l:line = substitute(l:line, '\v^#*[ ]*', '', '')
                let l:line = substitute(l:line, '\v[ ]*#*$', '', '')
            endif
            let l:level = s:GetHeaderLevel(i)
            let l:item = {'level': l:level, 'text': l:line, 'lnum': i, 'bufnr': bufnr}
            let l:header_list = l:header_list + [l:item]
        endif
    endfor
    return l:header_list
endfunction

function! typst#Toc(...)
    if a:0 > 0
        let l:window_type = a:1
    else
        let l:window_type = 'vertical'
    endif

    let l:cursor_line = line('.')
    let l:cursor_header = 0
    let l:header_list = s:GetHeaderList()
    let l:indented_header_list = []
    if len(l:header_list) == 0
        echom 'Toc: No headers.'
        return
    endif
    let l:header_max_len = 0
    let l:vim_markdown_toc_autofit = get(g:, 'vim_markdown_toc_autofit', 0)
    for h in l:header_list
        if l:cursor_header == 0
            let l:header_line = h.lnum
            if l:header_line == l:cursor_line
                let l:cursor_header = index(l:header_list, h) + 1
            elseif l:header_line > l:cursor_line
                let l:cursor_header = index(l:header_list, h)
            endif
        endif
        let l:text = repeat('  ', h.level-1) . h.text
        let l:total_len = strdisplaywidth(l:text)
        if l:total_len > l:header_max_len
            let l:header_max_len = l:total_len
        endif
        let l:item = {'lnum': h.lnum, 'text': l:text, 'valid': 1, 'bufnr': h.bufnr, 'col': 1}
        let l:indented_header_list = l:indented_header_list + [l:item]
    endfor

    " Open the TOC buffer in a new window
    let l:orig_winid = win_getid()
    let l:toc_bufnr = bufnr('TOC', 1)
    " execute 'sbuffer ' . l:toc_bufnr
    if a:0 > 0
        if a:1 == 'vertical'
            execute 'vsplit +buffer' . l:toc_bufnr
            if (&columns/2) > l:header_max_len && l:vim_markdown_toc_autofit == 1
                execute 'vertical resize ' . (l:header_max_len + 1 + 3)
            else
                execute 'vertical resize ' . (&columns/2)
            endif
        elseif a:1 == 'tab'
            execute 'tabnew | buffer' . l:toc_bufnr
        else
            execute 'sbuffer ' . l:toc_bufnr
        endif
    else
        execute 'sbuffer ' . l:toc_bufnr
    endif

    setlocal buftype=nofile
    setlocal bufhidden=delete
    call setbufline(l:toc_bufnr, 1, map(copy(l:indented_header_list), 'v:val.text'))
    let b:indented_header_list = l:indented_header_list
    let b:orig_winid = l:orig_winid

    " Define a mapping to jump to the corresponding line in the original file when a line is clicked
    nnoremap <buffer> <silent> <Enter> :call <SID>JumpToHeader()<CR>

    " Move the cursor to the current header in the TOC
    execute 'normal! ' . l:cursor_header . 'G'

endfunction

function! s:JumpToHeader()
    let l:lnum = line('.')
    let l:header_info = b:indented_header_list[l:lnum - 1]
    let l:orig_winid = b:orig_winid
    call win_execute(l:orig_winid, 'buffer ' . l:header_info.bufnr)
    call win_execute(l:orig_winid, 'normal! ' . l:header_info.lnum . 'G')
    if g:typst_auto_close_toc
        bwipeout!
    endif
    call win_gotoid(l:orig_winid)
endfunction

" Detect context for #51
" Detects the inner most syntax group under the cursor by default.
function! typst#synstack(kwargs = {}) abort 
    let l:pos = get(a:kwargs, 'pos', getcurpos()[1:3])
    let l:only_inner = get(a:kwargs, 'only_inner', v:true)
    if mode() ==# 'i'
        let l:pos[1] -= 1
    endif
    call map(l:pos, 'max([v:val, 1])')

    let l:stack = map(synstack(l:pos[0], l:pos[1]), "synIDattr(v:val, 'name')")
    return l:only_inner ? l:stack[-1:] : l:stack
endfunction

function! typst#in_markup(...) abort
    let l:stack = call('typst#synstack', a:000)
    let l:ret = empty(l:stack)
    for l:name in l:stack
        let l:ret = l:ret 
            \ || l:name =~? '^typstMarkup'
            \ || l:name =~? 'Bracket$'
    endfor
    return l:ret
endfunction

function! typst#in_code(...) abort
    let l:ret = v:false
    for l:name in call('typst#synstack', a:000)
        let l:ret = l:ret 
            \ || l:name =~? '^typstCode'
            \ || l:name =~? 'Brace$'
    endfor 
    return l:ret
endfunction

function! typst#in_math(...) abort
    let l:ret = v:false
    for l:name in call('typst#synstack', a:000)
        let l:ret = l:ret 
            \ || l:name =~? '^typstMath'
            \ || l:name =~? 'Dollar$'
    endfor
    return l:ret
endfunction

function! typst#in_comment(...) abort
    let l:ret = v:false
    for l:name in call('typst#synstack', a:000)
        let l:ret = l:ret 
            \ || l:name =~? '^typstComment'
    endfor
    return l:ret
endfunction


function! typst#foldexpr()
    let line = getline(v:lnum)

    " Whenever the user wants to fold nested headers under the parent
    let nested = g:typst_folding

    " Regular headers
    let depth = match(line, '\(^=\+\)\@<=\( .*$\)\@=')

    " Do not fold nested regular headers
    if depth > 1 && !nested
        let depth = 1
    endif

    if depth > 0
        " check syntax, it should be typstMarkupHeading
        let syncode = synstack(v:lnum, 1)
        if len(syncode) > 0 && synIDattr(syncode[0], 'name') ==# 'typstMarkupHeading'
            return ">" . depth
        endif
    endif

    return "="
endfunction
