" vim: set sw=2 ts=2 sts=2 foldmethod=marker:

if exists('git#ExecuteOrThrow')
  finish
endif

""""""""""""""""""""""""" Utils """""""""""""""""""""""""" {{{
function! git#GetBranch(...)
  let arg = get(a:000, 0, FugitiveGitDir())
  let dir = FugitiveExtractGitDir(arg)
  let dict = FugitiveExecute([dir, "branch", "--show-current"])
  if dict['exit_status'] != 0
    return ''
  endif
  return dict['stdout'][0]
endfunction

function! git#ExecuteOrThrow(args, ...)
  let dict = FugitiveExecute(a:args)
  if dict['exit_status'] != 0
    let msg = get(a:000, 0, printf("Git '%s' failed!", join(a:args)))
    call init#ShowErrors(dict['stderr'])
    throw msg
  endif
  return dict['stdout']
endfunction

function! git#EditFugitive()
  let actual = bufname()
  let real = FugitiveReal()
  if actual != real
    let pos = getpos(".")
    exe "edit " . FugitiveReal()
    call setpos(".", pos)
  endif
endfunction

function! git#GetObjectHash()
  let ret = split(FugitiveParse()[0], ":")
  if empty(ret)
    return ""
  else
    return ret[0]
  endif
endfunction

function! git#ShowChanges(arg)
  let arg = empty(a:arg) ? git#GetObjectHash() : a:arg
  if arg =~ '\x\{7,40\}'
    " Single commit only.
    let files = git#ExecuteOrThrow(["show", "--name-only", "--pretty=format:", arg])
    let bpoint = git#HashOrThrow(arg .. "~1")
  elseif !empty(arg)
    " Changes made by branch (relative to mainline).
    let mainline = git#GetMasterOrThrow(v:true)
    let bpoint = git#CommonParentOrThrow(arg, mainline)
    let range = printf('%s..%s', bpoint, arg)
    let files = git#ExecuteOrThrow(["diff", "--name-only", range])
  else
    echo "No valid start point!"
    return
  endif
  call filter(files, '!empty(v:val)')
  let repo = FugitiveWorkTree() .. '/'
  call map(files, 'repo .. v:val')

  sp
  let fugitive_objects = []
  for file in files
    let url = FugitiveFind(printf("%s:%s", arg, file))
    let nr = bufadd(url)
    call add(fugitive_objects, url)
    call setbufvar(nr, 'commitish', bpoint)
  endfor
  quit

  call DisplayInQf(fugitive_objects, 'Changes')
endfunction

function! git#NextContext(reverse)
  call search('^\(@@ .* @@\|[<=>|]\{7}[<=>|]\@!\)', a:reverse ? 'bW' : 'W')
endfunction

function! git#ContextMotion()
  call s:Context(v:false)
  let end = line('.')
  call s:Context(v:true)
  exe printf("normal V%dG", end)
endfunction
""}}}

""""""""""""""""""""""""" Diff open """""""""""""""""""""""""" {{{
function! git#DiffWinid()
  " Load all windows in tab
  let winids = gettabinfo(tabpagenr())[0]["windows"]
  let winfos = map(winids, "getwininfo(v:val)[0]")
  " Ignore quickfix
  let winfos = filter(winfos, "v:val.quickfix != 1")

  " Consider two way diffs only
  if len(winfos) != 2
    return -1
  endif
  " Both buffers should have 'diff' set
  if win_execute(winfos[0].winid, "echon &diff") != "1" || win_execute(winfos[1].winid, "echon &diff") != "1"
    return -1
  endif
  " Consider diffs comming from fugitive plugin only
  if bufname(winfos[0].bufnr) =~# "^fugitive:///"
    return winfos[0].winid
  endif
  if bufname(winfos[1].bufnr) =~# "^fugitive:///"
    return winfos[1].winid
  endif
  return -1
endfunction

function! git#CanStartDiff()
  " Load all windows in tab
  let winids = gettabinfo(tabpagenr())[0]["windows"]
  let winfos = map(winids, "getwininfo(v:val)[0]")
  " Ignore quickfix
  let winfos = filter(winfos, "v:val.quickfix != 1")
  " Only a single file can be opened
  if len(winfos) != 1
    return 0
  endif
  " Must exist on disk (or fugitive object)
  let bufnr = winfos[0].bufnr
  let name = bufname(bufnr)
  if name[:11] != "fugitive:///" && !filereadable(name)
    return 0
  endif
  " Must be inside git
  return !empty(FugitiveGitDir(bufnr))
endfunction

function! git#DiffToggle()
  let winid = git#DiffWinid()
  if winid >= 0
    let bufnr = getwininfo(winid)[0].bufnr
    if getbufvar(bufnr, '&mod') == 1
      echo "No write since last change"
      return
    endif
    let name = bufname(bufnr)
    let commitish = split(FugitiveParse(name)[0], ":")[0]
    " Memorize the last diff commitish for the buffer
    call setbufvar(bufnr, 'commitish', commitish)
    " Close fugitive window
    call win_gotoid(winid)
    quit
  elseif git#CanStartDiff()
    cclose
    let was_winid = win_getid()
    if exists("b:commitish") && b:commitish != "0"
      exe "lefta Gdiffsplit " . b:commitish
    else
      exe "lefta Gdiffsplit"
    endif
    call win_gotoid(was_winid)
  endif
endfunction
""}}}

""""""""""""""""""""""""" Diff mappings """""""""""""""""""""""""" {{{
function! git#DiffOtherExecute(cmd)
  let winids = gettabinfo(tabpagenr())[0]['windows']
  if winids[0] != win_getid()
    call win_gotoid(winids[0])
    exe a:cmd
    call win_gotoid(winids[1])
  else
    call win_gotoid(winids[1])
    exe a:cmd
    call win_gotoid(winids[0])
  endif
endfunction

function! git#DiffToggleMaps()
  if v:option_new
    " Diff put
    nnoremap <expr> dp init#Operator("diffput", 1)
    nnoremap <expr> dP init#Operator("diffput", 0)
    " Diff get
    nnoremap <expr> do init#Operator("diffget", 1)
    nnoremap <expr> dO init#Operator("diffget", 0)
    " Undoing diffs
    nnoremap dpu <cmd>call git#DiffOtherExecute("undo")<CR>
    " Saving diffs
    nnoremap dpw <cmd>call git#DiffOtherExecute("write")<CR>
    " Good ol' regular diff commands
    nnoremap dpp dp
    nnoremap doo do
    " Visual mode
    vnoremap dp :diffput<CR>
    vnoremap do :diffget<CR>
  else
    let normal_list = ["dp", "dP", "do", "dO", "dpu", "dpw", "dpp", "dpp"]
    for bind in normal_list
      silent! "nunmap " . bind
    endfor
    " Visual mode
    silent! vunmap dp
    silent! vunmap do
  endif
endfunction
""}}}

""""""""""""""""""""""""" Utils that throw """""""""""""""""""""""""" {{{
function! git#InsideGitOrThrow()
  let dict = FugitiveExecute(["status"])
  if dict['exit_status'] != 0
    throw "Not inside repo!"
  endif
endfunction

function! git#IsClean(...)
  let arg = get(a:000, 0, FugitiveGitDir())
  let dir = FugitiveExtractGitDir(arg)
  let dict = FugitiveExecute([dir, "status", "--porcelain"])
  return dict['exit_status'] == 0 && dict['stdout'] == ['']
endfunction

function! git#CleanOrThrow(...)
  if a:0 > 0
    let clean = git#IsClean(a:1)
  else
    let clean = git#IsClean()
  endif

  if !clean
    throw "Work tree not clean"
  endif
endfunction

function! git#GetBranchOrThrow()
  let output = git#ExecuteOrThrow(["rev-parse", "--abbrev-ref", "HEAD"], "Not inside repo!")
  return output[0]
endfunction

function! git#BranchOrThrow(arg)
  call git#CleanOrThrow()
  call git#ExecuteOrThrow(["checkout", a:arg], "Failed to checkouot " .. a:arg)
  call git#ExecuteOrThrow(["submodule", "update", "--init", "--recursive"], "Submodule update failed!")
endfunction

function! git#GetRefs(ref_prefix, arg)
  let dict = FugitiveExecute(['for-each-ref', '--format=%(refname)'])
  if dict['exit_status'] != 0
    return []
  endif
  let refs = dict['stdout']
  let prefix_len = strlen(a:ref_prefix)
  call filter(refs, 'v:val[:prefix_len-1] == a:ref_prefix')
  call map(refs, 'v:val[prefix_len:]')
  call filter(refs, 'stridx(v:val, a:arg) >= 0')
  return refs
endfunction

function! git#GetMasterOrThrow(remote)
  " TODO make candidates configurable
  if a:remote
    let refs_dir = 'refs/remotes/'
    let candidates = ['origin/obsidian-master', 'origin/master', 'origin/main']
  else
    let refs_dir = 'refs/heads/'
    let candidates = ['obsidian-master', 'master', 'main']
  endif
  let branches = git#GetRefs(refs_dir, 'ma')
  for candidate in candidates
    if index(branches, candidate) >= 0
      return candidate
    endif
  endfor
  throw "Failed to determine mainline."
endfunction

function! git#HashOrThrow(commitish)
  let msg = "Failed to parse " .. a:commitish
  let output = git#ExecuteOrThrow(["rev-parse", a:commitish], msg)
  return output[0]
endfunction

function! git#BranchCommitsOrThrow(branch, main)
  let range = printf("%s..%s", a:main, a:branch)
  let cmd = ["log", range, "--pretty=format:%H"]
  return git#ExecuteOrThrow(cmd, "Revision range failed!")
endfunction

function! git#CommonParentOrThrow(branch, main)
  let range = git#BranchCommitsOrThrow(a:branch, a:main)
  let branch_first = range[-1]
  if empty(branch_first)
    " 'branch' and 'main' are the same commits
    return a:main
  endif
  " Go 1 back to find the common commit
  let msg = "Failed to go back 1 commit from " . branch_first
  let output = git#ExecuteOrThrow(["rev-parse", branch_first . "~1"], msg)
  return output[0]
endfunction

function! git#RefExistsOrThrow(commit)
  let msg = "Unknown ref to git: " . a:commit
  call git#ExecuteOrThrow(["show", a:commit], msg)
endfunction
""}}}

""""""""""""""""""""""""" Commands """""""""""""""""""""""""" {{{
function! git#GetUnstaged()
  let dict = FugitiveExecute(["ls-files", "--exclude-standard", "--modified"])
  if dict['exit_status'] != 0
    return []
  endif
  let files = filter(dict['stdout'], "!empty(v:val)")
  if empty(files)
    return []
  endif
  " Git reports these duplicated sometimes
  call uniq(sort(files))
  return map(files, "FugitiveFind(v:val)")
endfunction

function! UnstagedCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return git#GetUnstaged()->TailItems(a:ArgLead)
endfunction

function! git#GetUntracked()
  let dict = FugitiveExecute(["ls-files", "--exclude-standard", "--others"])
  if dict['exit_status'] != 0
    return []
  endif
  let files = filter(dict['stdout'], "!empty(v:val)")
  if empty(files)
    return []
  endif
  return map(files, "FugitiveFind(v:val)")
endfunction

function! UntrackedCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return s:GetUntracked(bang)->TailItems(a:ArgLead)
endfunction

function! git#OpenBranchBufferOrThrow()
  let cmd = ["for-each-ref", "--sort=-committerdate", "refs/heads/", "--format=%(refname:short)"]
  let branches = git#ExecuteOrThrow(cmd)
  call filter(branches, '!empty(v:val)')
  call init#CreateOneShotQuickfix('Branches', branches, 'git#SelectBranch')
endfunction

function! git#SelectBranch(branch)
  try
    call git#BranchOrThrow(a:branch)
  catch
    echo v:exception
  endtry
endfunction

function! git#BranchCommand(args)
  try
    call git#CleanOrThrow()
    if empty(a:args)
      call git#OpenBranchBufferOrThrow()
    else
      call git#BranchOrThrow(a:args)
    endif
  catch
    echo v:exception
  endtry
endfunction

function! BranchCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return git#GetRefs('refs/heads/', a:ArgLead)
endfunction

function! git#PullCommand(bang)
  try
    let branch = FugitiveHead()
    let check_file = printf("%s/refs/remotes/origin/%s", FugitiveGitDir(), branch)
    if !filereadable(check_file)
      call init#Warn("Could not find origin/" .. branch)
    endif

    let args = ["fetch", "origin", branch]
    call git#ExecuteOrThrow(args, "Failed to fetch!")

    const range = printf("%s..origin/%s", branch, branch)
    let args = ["log", "--pretty=format:%h", range]
    let output = git#ExecuteOrThrow(args, "Failed to log changes!")
    const commits = filter(output, "!empty(v:val)")

    if len(commits) <= 0
      echo "No changes."
      return
    endif

    if !empty(a:bang)
      let args = ["reset", "--hard", "origin/" .. branch]
      let msg = "Force reset failed. Dirty repo?"
    else
      let args = ["merge", "--ff-only", "origin/" .. branch]
      let msg = "Merge failed. Conflicts?"
    endif
    call git#ExecuteOrThrow(args, msg)
    exe printf("G log -n %d %s", len(commits), commits[0])
    echo printf("Total %d commits", len(commits))
  catch
    echo v:exception
  endtry
endfunction

function! git#PushCommand(bang)
  try
    if !empty(a:bang)
      call git#ExecuteOrThrow(["push", "--force", "origin", "HEAD"])
    else
      call git#CleanOrThrow()
      call git#ExecuteOrThrow(["push", "origin", "HEAD"])
    endif
    echo "Up to date with origin."
    return v:true
  catch
    echo v:exception
    return v:false
  endtry
endfunction

function! OriginCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  if !git#IsClean()
    return []
  endif

  call FugitiveExecute(['fetch', 'origin'])
  return git#GetRefs('refs/remotes/origin/', a:ArgLead)
endfunction

function! git#RecentRefs(max_refs)
  let max_refs = a:max_refs
  if type(max_refs) == v:t_number
    let max_refs = string(max_refs)
  endif
  let dict = FugitiveExecute(["reflog", "-n", max_refs, "--pretty=format:%H"])
  if dict['exit_status'] != 0
    return []
  endif
  let hashes = init#Unique(dict['stdout'])
  let dict = FugitiveExecute(["name-rev", "--annotate-stdin", "--name-only"], #{stdin: hashes})
  if dict['exit_status'] != 0
    return []
  endif
  let refs = dict['stdout']
  call filter(refs, "!empty(v:val)")
  return refs
endfunction

function! ReflogCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let refs = git#RecentRefs(30)
  call filter(refs, "stridx(v:val, a:ArgLead) >= 0")
  return refs[1:]
endfunction

function! git#DangleCommand()
  let refs = git#RecentRefs(100)
  call filter(refs, 'v:val =~# "^\\x*$"')
  call init#CreateCustomQuickfix('Dangling commits', refs, 'git#ShowDanglingCommit')
endfunction

function! git#ShowDanglingCommit()
  let ns = nvim_create_namespace('dangling_commits')
  call nvim_buf_set_extmark(bufnr(), ns, line('.') - 1, 0, #{line_hl_group: "Conceal"})
  exe "G log " .. getline(".")
endfunction

function! git#BaselineOrThrow(...)
  let arg = get(a:000, 0, '')
  call git#InsideGitOrThrow()
  " Determine main branch
  let head = git#HashOrThrow("HEAD")
  let mainline = empty(arg) ? git#GetMasterOrThrow(v:true) : arg
  call git#RefExistsOrThrow(mainline)
  return git#CommonParentOrThrow(head, mainline)
endfunction

function! git#SquashCommand()
  try
    let bpoint = git#BaselineOrThrow()
    exe "Git rebase -i " .. bpoint
  catch
    echom v:exception
  endtry
endfunction

function! git#RebaseCommand()
  try
    let main = git#GetMasterOrThrow(v:false)
    call git#ExecuteOrThrow(["fetch", "origin", main])
    call git#ExecuteOrThrow(["rebase", "origin/" .. main])
    echo "Rebased onto fresh origin/"  .. main
  catch
    echo v:exception
  endtry
endfunction
""}}}

""""""""""""""""""""""""" Review """"""""""""""""""""""""""" {{{
function! git#Review(bang, arg)
  try
    " Refresh current state of review
    if exists("g:git_review_stack")
      if !empty(a:bang)
        unlet g:git_review_stack
      else
        let items = g:git_review_stack[-1]
        call DisplayInQf(items, "Review")
        echo "Review in progress, refreshing quickfix..."
        return
      endif
    endif

    let bpoint = git#BaselineOrThrow(a:arg)
    " Load files for review.
    " If possible, make the diff windows editable by not passing a ref to fugitive
    if get(a:, "arg", "") == "HEAD"
      exe "Git difftool --name-only"
      let bufs = map(getqflist(), "v:val.bufnr")
      call map(bufs, 'setbufvar(v:val, "commitish", "0")')
    else
      exe "Git difftool --name-only " . bpoint
      let bufs = map(getqflist(), "v:val.bufnr")
      call map(bufs, 'setbufvar(v:val, "commitish", bpoint)')
    endif
    if empty(getqflist())
      echo "Nothing to show."
      cclose
    else
      let items = s:OrderReviewItems(getqflist())
      call DisplayInQf(items, "Review")
      let g:git_review_stack = [items]
    endif
  catch
    echo v:exception
  endtry
endfunction

function! s:OrderReviewItems(items)
  let items = a:items
  call assert_true(!empty(items))
  let commitish = getbufvar(items[0].bufnr, "commitish")
  if commitish == "0"
    let commitish = "HEAD"
  endif
  let cmd = ["diff", "--numstat", commitish, '--']
  let files = map(copy(items), 'bufname(v:val.bufnr)')
  call extend(cmd, files)

  let changes = git#ExecuteOrThrow(cmd)
  for idx in range(len(changes))
    if !empty(changes[idx])
      let [added, deleted; _] = split(changes[idx])
      let items[idx].text = printf('%s insertions(+), %s deletions(-)', added, deleted)
      let items[idx].order = added + deleted
    endif
  endfor
  return sort(items, {a, b -> a.order - b.order})
endfunction

function! git#CompleteFiles(cmd_bang, arg) abort
  if !exists("g:git_review_stack")
    echo "Start a review first"
    return
  endif
  " Close diff
  if git#DiffWinid() >= 0
    call git#DiffToggle()
  endif

  let new_items = copy(g:git_review_stack[-1])
  if !empty(a:arg)
    let idx = printf("stridx(bufname(v:val.bufnr), %s)", string(a:arg))
    let comp = a:cmd_bang == "!" ? " != " : " == "
    let new_items = filter(new_items, idx . comp . "-1")
    let n = len(g:git_review_stack[-1]) - len(new_items)
    echo "Completed " . n . " files"
  else
    let comp = a:cmd_bang == "!" ? " == " : " != "
    let bufnr = bufnr(FugitiveReal(bufname("%")))
    let new_items = filter(new_items, "v:val.bufnr" . comp . bufnr)
  endif
  call add(g:git_review_stack, new_items)
  if empty(new_items)
    call init#Warn("Review completed")
    unlet g:git_review_stack
  else
    call DisplayInQf(new_items, "Review")
    cc
  endif
endfunction

function CompleteCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  if !exists('g:git_review_stack')
    return []
  endif
  return SplitItems(g:git_review_stack[-1], a:ArgLead)
endfunction

function! git#PostponeFile()
  if !exists("g:git_review_stack")
    echo "Start a review first"
    return
  endif
  let list = g:git_review_stack[-1]
  let nrs = map(copy(list), "v:val.bufnr")
  let idx = index(nrs, bufnr())
  if idx < 0
    return
  endif
  let item = remove(list, idx)
  call add(list, item)

  " Close diff
  if git#DiffWinid() >= 0
    call git#DiffToggle()
  endif
  " Refresh quickfix
  call DisplayInQf(list, "Review")
  cc
endfunction

function! git#UncompleteFiles()
  if !exists("g:git_review_stack")
    echo "Start a review first"
    return
  endif
  if len(g:git_review_stack) > 1
    call remove(g:git_review_stack, -1)
    let items = g:git_review_stack[-1]
    call DisplayInQf(items, "Review")
  endif
endfunction
""}}}

""""""""""""""""""""""""" Pickaxe """"""""""""""""""""""""""" {{{
function! git#Pickaxe(keyword)
  try
    call git#InsideGitOrThrow()
    " Determine branch.
    let head = git#HashOrThrow("HEAD")
    let mainline = git#GetMasterOrThrow(v:false)
    let commits = git#BranchCommitsOrThrow(head, mainline)
    " Add a fake commit for unstanged changes
    call add(commits, "0000000000000000000000000000000000000000")
    " Get changed files.
    let cmd = ["diff", "HEAD~" .. len(commits), "--name-only"]
    let files = git#ExecuteOrThrow(cmd, "Collecting changed files failed!")
    call map(files, 'FugitiveFind(v:val)')
    " Run git bame on each file
    let output = []
    for file in files
      let dict = FugitiveExecute(["blame", "-p", "--", file])
      if dict['exit_status'] != 0
        " File might have been deleted
        continue
      endif
      let blame = dict['stdout']
      let idx = 0
      while idx < len(blame)
        if blame[idx] =~# '^\x\{40\}'
          let [_, commit, orig_lnum, lnum; _] = matchlist(blame[idx], '\(\x*\) \(\d*\) \(\d*\)')
          if index(commits, commit) >= 0
            while blame[idx][0] != "\t"
              let idx += 1
            endwhile
            if stridx(blame[idx], a:keyword) >= 0
              call add(output, #{filename: file, lnum: lnum, text: blame[idx][1:]})
            endif
          endif
        endif
        let idx += 1
      endwhile
    endfor
    call DisplayInQf(output, 'Pickaxe')
  catch
    echo v:exception
  endtry
endfunction
""}}}

""""""""""""""""""""""""" Install """"""""""""""""""""""""""" {{{
function! git#Install()
  nnoremap <silent> <leader>fug <cmd> call git#EditFugitive()<CR>
  nnoremap <silent> [n <cmd> call git#NextContext(v:true)<CR>
  nnoremap <silent> ]n <cmd> call git#NextContext(v:false)<CR>
  omap an <cmd> call git#ContextMotion()<CR>

  nnoremap <silent> <leader>dif <cmd> call git#DiffToggle()<CR>
  autocmd! OptionSet diff call git#DiffToggleMaps()

  command! -nargs=? -complete=customlist,BranchCompl Changes
        \ call git#ShowChanges(<q-args>)

  command! -nargs=? -complete=customlist,UnstagedCompl Dirty
        \ call git#GetUnstaged()->FileFilter(<q-args>)->DropInQf("Unstaged")

  command! -nargs=? -complete=customlist,UntrackedCompl Untracked
        \ call git#GetUntracked()->FileFilter(<q-args>)->DropInQf("Untracked")

  command! -nargs=? -complete=customlist,BranchCompl Branch call git#BranchCommand(<q-args>)

  command! -nargs=1 -bang -complete=customlist,OriginCompl Origin
        \ call git#BranchOrThrow(<q-args>)

  command! -bang -nargs=0 Pull call git#PullCommand("<bang>")

  command -nargs=1 -bang -complete=customlist,ReflogCompl Reflog
        \ call git#BranchOrThrow(<q-args>)
  cabbr Ref Reference

  command! -nargs=0 Dangle call git#DangleCommand()

  command! -nargs=? -complete=customlist,BranchCompl Base call init#ToClipboard(git#BaselineOrThrow(<q-args>))
  command! Squash call git#SquashCommand()
  command! -nargs=0 Rebase call git#RebaseCommand()

  command! -nargs=? -bang -complete=customlist,BranchCompl Review call git#Review("<bang>", <q-args>)
  command! -nargs=0 -bang D Review<bang> HEAD
  command! -nargs=? -bang R Review<bang> <args>
  command! -bang -nargs=? -complete=customlist,CompleteCompl Complete call git#CompleteFiles('<bang>', <q-args>)
  command! -nargs=0 Uncomplete call git#UncompleteFiles()

  nnoremap <silent> <leader>ok <cmd> Complete<CR>
  nnoremap <silent> <leader>nok <cmd> call git#PostponeFile()<CR>

  command! -nargs=0 Todo call git#Pickaxe('TODO')
  command! -nargs=* Pickaxe call git#Pickaxe(<q-args>)
endfunction

if get(g:, 'git_install', v:false)
  call git#Install()
endif
""}}}
