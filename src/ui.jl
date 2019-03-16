const rebug_prompt_string = "rebug> "
const rebug_prompt_ref = Ref{Union{LineEdit.Prompt,Nothing}}(nothing)       # set by __init__
const interpret_prompt_ref = Ref{Union{LineEdit.Prompt,Nothing}}(nothing)   # set by __init__

# For debugging
function logaction(msg)
    open("/tmp/rebugger.log", "a") do io
        println(io, "* ", msg)
        flush(io)
    end
    nothing
end

dummy() = nothing
const dummymethod = first(methods(dummy))
const dummyuuid   = UUID(UInt128(0))

uuidextractor(str) = match(r"getstored\(\"([a-z0-9\-]+)\"\)", str)

mutable struct RebugHeader <: AbstractHeader
    warnmsg::String
    errmsg::String
    uuid::UUID
    current_method::Method
    nlines::Int   # size of the printed header
end
RebugHeader() = RebugHeader("", "", dummyuuid, dummymethod, 0)

mutable struct InterpretHeader <: AbstractHeader
    frame::Union{Nothing,Frame}
    leveloffset::Int
    val
    bt
    warnmsg::String
    errmsg::String
    nlines::Int   # size of the printed header
end
InterpretHeader() = InterpretHeader(nothing, 0, nothing, nothing, "", "", 0)

struct DummyAST end  # fictive input for the put!/take! evaluation by the InterpretREPL backend

header(s::LineEdit.MIState) = header(mode(s).repl)
header(repl::HeaderREPL) = repl.header
header(::LineEditREPL) = header(rebug_prompt_ref[].repl)  # default to the Rebug header

# Custom methods
set_method!(header::RebugHeader, method::Method) = header.current_method = method

function set_uuid!(header::RebugHeader, uuid::UUID)
    if haskey(stored, uuid)
        header.uuid = uuid
        header.current_method = stored[uuid].method
    else
        header.uuid = dummyuuid
        header.current_method = dummymethod
    end
    uuid
end

function set_uuid!(header::RebugHeader, str::AbstractString)
    m = uuidextractor(str)
    uuid = if m isa RegexMatch && length(m.captures) == 1
        UUID(m.captures[1])
    else
        dummyuuid
    end
    set_uuid!(header, uuid)
end

struct FakePrompt{Buf<:IO}
    input_buffer::Buf
end
LineEdit.mode(p::FakePrompt) = rebug_prompt_ref[]

"""
    stepin(s)

Given a buffer `s` representing a string and "point" (the seek position) set at a call expression,
replace the contents of the buffer with a `let` expression that wraps the *body* of the callee.

For example, if `s` has contents

    <some code>
    if x > 0.5
        ^fcomplex(x)
        <more code>

where in the above `^` indicates `position(s)` ("point"), and if the definition of `fcomplex` is

    function fcomplex(x::A, y=1, z=""; kw1=3.2) where A<:AbstractArray{T} where T
        <body>
    end

rewrite `s` so that its contents are

    @eval ModuleOf_fcomplex let (x, y, z, kw1, A, T) = Main.Rebugger.getstored(id)
        <body>
    end

where `Rebugger.getstored` returns has been pre-loaded with the values that would have been
set when you called `fcomplex(x)` in `s` above.
This line can be edited and `eval`ed at the REPL to analyze or improve `fcomplex`,
or can be used for further `stepin` calls.
"""
function stepin(s::LineEdit.MIState)
    # Add the command we're tracing to the history. That way we can go "up the call stack".
    pos = position(s)
    cmd = String(take!(copy(LineEdit.buffer(s))))
    add_history(s, cmd)
    # Analyze the command string and step in
    local uuid, letcmd
    try
        uuid, letcmd = stepin(LineEdit.buffer(s))
    catch err
        repl = rebug_prompt_ref[].repl
        handled = false
        if err isa StashingFailed
            repl.header.warnmsg = "Execution did not reach point"
            handled = true
        elseif err isa Meta.ParseError || err isa StepException
            repl.header.warnmsg = "Expression at point is not a call expression"
            handled = true
        elseif err isa EvalException
            io = IOBuffer()
            showerror(io, err.exception)
            errstr = String(take!(io))
            repl.header.errmsg = "$errstr while evaluating $(err.exprstring)"
            handled = true
        elseif err isa DefMissing
            repl.header.errmsg = "The expression for method $(err.method) was unavailable. Perhaps it was untracked or generated by code."
            handled = true
        end
        if handled
            buf = LineEdit.buffer(s)
            LineEdit.edit_clear(buf)
            write(buf, cmd)
            seek(buf, pos)
            return nothing
        end
        rethrow(err)
    end
    set_uuid!(header(s), uuid)
    LineEdit.edit_clear(s)
    LineEdit.edit_insert(s, letcmd)
    return nothing
end

function capture_stacktrace(s)
    if mode(s) isa LineEdit.PrefixHistoryPrompt
        # history search, re-enter with the corresponding mode
        LineEdit.accept_result(s, mode(s))
        return capture_stacktrace(s)
    end
    cmdstring = LineEdit.content(s)
    add_history(s, cmdstring)
    print(REPL.terminal(s), '\n')
    expr = Meta.parse(cmdstring)
    local uuids
    try
        uuids = capture_stacktrace(expr)
    catch err
        print(stderr, err)
        return nothing
    end
    io = IOBuffer()
    buf = FakePrompt(io)
    hp = mode(s).hist
    for uuid in uuids
        println(io, generate_let_command(uuid))
        REPL.add_history(hp, buf)
        take!(io)
    end
    hp.cur_idx = length(hp.history) + 1
    if !isempty(uuids)
        set_uuid!(header(s), uuids[end])
        print(REPL.terminal(s), '\n')
        LineEdit.edit_clear(s)
        LineEdit.enter_prefix_search(s, find_prompt(s, LineEdit.PrefixHistoryPrompt), true)
    end
    return nothing
end

function add_history(s, str::AbstractString)
    io = IOBuffer()
    buf = FakePrompt(io)
    hp = mode(s).hist
    println(io, str)
    REPL.add_history(hp, buf)
end

function interpret(s)
    hdr = header(s)
    hdr.bt = nothing
    term = REPL.terminal(s)
    cmdstring = LineEdit.content(s)
    isempty(cmdstring) && return :done
    add_history(s, cmdstring)
    expr = Meta.parse(cmdstring)
    tupleexpr = JuliaInterpreter.extract_args(Main, expr)
    callargs = Core.eval(Main, tupleexpr)   # get the elements of the call
    callexpr = Expr(:call, callargs...)
    frame = JuliaInterpreter.enter_call_expr(callexpr)
    if frame === nothing
        local val
        try
            hdr.val = Core.eval(Main, callexpr)
        catch err
            hdr.val = err
            hdr.bt = catch_backtrace()
        end
    else
        hdr.frame = frame
        deflines = expression_lines(JuliaInterpreter.scopeof(frame))

        print(term, '\n') # to advance beyond the user's input line
        nlines = 0
        try
            while true
                HeaderREPLs.clear_nlines(term, nlines)
                print_header(term, hdr)
                if hdr.leveloffset == 0
                    nlines = show_code(term, frame, deflines, nlines)
                else
                    f, Δ = frameoffset(frame, hdr.leveloffset)
                    hdr.leveloffset -= Δ
                    nlines = show_code(term, f, expression_lines(JuliaInterpreter.scopeof(f)), nlines)
                end
                cmd = read(term, Char)
                if cmd == '?'
                    hdr.warnmsg = """
                    Commands:
                      space: next line
                      enter: continue to next breakpoint or completion
                          →: step in to next call
                          ←: finish frame and return to caller
                          ↑: display the caller frame
                          ↓: display the callee frame
                          b: insert breakpoint at current line
                          c: insert conditional breakpoint at current line
                          r: remove breakpoint at current line
                          d: disable breakpoint at current line
                          e: enable breakpoint at current line
                          q: abort (returns nothing)"""
                elseif cmd == ' '
                    hdr.leveloffset = 0
                    ret = debug_command(frame, :n)
                    if ret === nothing
                        hdr.val = JuliaInterpreter.get_return(root(frame))
                        break
                    end
                    frame, deflines = refresh(frame, ret, deflines)
                elseif cmd == '\n' || cmd == '\r'
                    hdr.leveloffset = 0
                    ret = debug_command(frame, :c)
                    if ret === nothing
                        hdr.val = JuliaInterpreter.get_return(root(frame))
                        break
                    end
                    frame, deflines = refresh(frame, ret, deflines)
                elseif cmd == 'q'
                    hdr.val = nothing
                    break
                elseif cmd == '\e'   # escape codes
                    nxtcmd = read(term, Char)
                    nxtcmd == "O" && (nxtcmd = '[')  # normalize escape code
                    cmd *= nxtcmd
                    while nxtcmd == '['
                        nxtcmd = read(term, Char)
                        cmd *= nxtcmd
                    end
                    if cmd == "\e[C"  # right arrow
                        hdr.leveloffset = 0
                        ret = debug_command(frame, :s)
                        frame, deflines = refresh(frame, ret, deflines)
                    elseif cmd == "\e[D"  # left arrow
                        hdr.leveloffset = 0
                        ret = debug_command(frame, :finish)
                        if ret === nothing
                            hdr.val = JuliaInterpreter.get_return(root(frame))
                            break
                        end
                        frame, deflines = refresh(frame, ret, deflines)
                    elseif cmd == "\e[A"  # up arrow
                        hdr.leveloffset += 1
                    elseif cmd == "\e[B"  # down arrow
                        hdr.leveloffset = max(0, hdr.leveloffset - 1)
                    end
                elseif cmd == 'b'
                    JuliaInterpreter.breakpoint!(frame.framecode, frame.pc)
                elseif cmd == 'c'
                    print(term, "enter condition: ")
                    condstr = ""
                    c = read(term, Char)
                    while c != '\n' && c != '\r'
                        print(term, c)
                        condstr *= c
                        c = read(term, Char)
                    end
                    condex = Base.parse_input_line(condstr; filename="condition")
                    JuliaInterpreter.breakpoint!(frame.framecode, frame.pc, (JuliaInterpreter.moduleof(frame), condex))
                elseif cmd == 'r'
                    thisline = JuliaInterpreter.linenumber(frame)
                    breakpoint_action(remove, frame, thisline)
                elseif cmd == 'd'
                    thisline = JuliaInterpreter.linenumber(frame)
                    breakpoint_action(disable, frame, thisline)
                elseif cmd == 'e'
                    thisline = JuliaInterpreter.linenumber(frame)
                    breakpoint_action(enable, frame, thisline)
                else
                    push!(msgs, cmd)
                end
                hdr.frame = frame
            end
        catch err
            hdr.val = err
            hdr.bt = catch_backtrace()
        end
    end
    # Store the result
    put!(REPL.backend(mode(s).repl).response_channel, (hdr.val, hdr.bt))
    hdr.frame = nothing
    return :done
end

function refresh(frame, ret, deflines)
    @assert ret !== nothing
    cframe, _ = ret
    if cframe === frame
        return frame, deflines
    end
    return cframe, expression_lines(JuliaInterpreter.scopeof(cframe))
end

# Find the range of statement indexes that preceed a line
# `thisline` should be in "compiled" numbering
function coderange(src::CodeInfo, thisline)
    codeloc = searchsortedfirst(src.linetable, LineNumberNode(thisline, ""); by=x->x.line)
    if codeloc == 1
        return 1:1
    end
    idxline = searchsortedfirst(src.codelocs, codeloc)
    idxprev = searchsortedfirst(src.codelocs, codeloc-1) + 1
    return idxprev:idxline
end
coderange(framecode::FrameCode, thisline) = coderange(framecode.src, thisline)

function breakpoint_action(f, frame, thisline)
    framecode = frame.framecode
    breakpoints = framecode.breakpoints
    for i in coderange(framecode.src, thisline)
        if isassigned(breakpoints, i) && (breakpoints[i].isactive || breakpoints[i].condition != JuliaInterpreter.falsecondition)
            f(JuliaInterpreter.BreakpointRef(framecode, i))
        end
    end
    return nothing
end

### REPL modes

function HeaderREPLs.setup_prompt(repl::HeaderREPL{RebugHeader}, hascolor::Bool)
    julia_prompt = find_prompt(repl.interface, "julia")

    prompt = REPL.LineEdit.Prompt(
        rebug_prompt_string;
        prompt_prefix = hascolor ? repl.prompt_color : "",
        prompt_suffix = hascolor ?
            (repl.envcolors ? Base.input_color : repl.input_color) : "",
        complete = julia_prompt.complete,
        on_enter = REPL.return_callback)

    prompt.on_done = HeaderREPLs.respond(repl, julia_prompt) do str
        Base.parse_input_line(str; filename="REBUG")
    end
    # hist will be handled automatically if repl.history_file is true
    # keymap_dict is separate
    return prompt, :rebug
end

function HeaderREPLs.append_keymaps!(keymaps, repl::HeaderREPL{RebugHeader})
    julia_prompt = find_prompt(repl.interface, "julia")
    kms = [
        trigger_search_keymap(repl),
        mode_termination_keymap(repl, julia_prompt),
        trigger_prefix_keymap(repl),
        REPL.LineEdit.history_keymap,
        REPL.LineEdit.default_keymap,
        REPL.LineEdit.escape_defaults,
    ]
    append!(keymaps, kms)
end

# To get it to parse the UUID whenever we move through the history, we have to specialize
# this method
function HeaderREPLs.activate_header(header::RebugHeader, p, s, termbuf, term)
    str = String(take!(copy(LineEdit.buffer(s))))
    set_uuid!(header, str)
end

## Interpret also requires a separate repl

function HeaderREPLs.setup_prompt(repl::HeaderREPL{InterpretHeader}, hascolor::Bool)
    julia_prompt = find_prompt(repl.interface, "julia")

    prompt = REPL.LineEdit.Prompt(
        "interpret> ";   # should never be shown
        prompt_prefix = hascolor ? repl.prompt_color : "",
        prompt_suffix = hascolor ?
            (repl.envcolors ? Base.input_color : repl.input_color) : "",
        complete = julia_prompt.complete,
        on_enter = REPL.return_callback)

    prompt.on_done = HeaderREPLs.respond(repl, julia_prompt) do str
        return DummyAST()
    end
    return prompt, :rebug
end

function HeaderREPLs.append_keymaps!(keymaps, repl::HeaderREPL{InterpretHeader})
    # No keymaps
    return keymaps
end

function HeaderREPLs.activate_header(header::InterpretHeader, p, s, termbuf, term)
end

function Base.put!(c::Channel, input::Tuple{DummyAST,Int})
    return nothing
end

const keybindings = Dict{Symbol,String}(
    :stacktrace => "\es",                        # Alt-s ("[s]tacktrace")
    :stepin => "\ee",                            # Alt-e ("[e]nter")
    :interpret => "\ei",                         # Alt-i ("[i]nterpret")
)

const modeswitches = Dict{Any,Any}(
    :stacktrace => (s, o...) -> capture_stacktrace(s),
    :stepin => (s, o...) -> (stepin(s); enter_rebug(s)),
    :interpret => (s, o...) -> (enter_interpret(s); interpret(s)),
)

function get_rebugger_modeswitch_dict()
    rebugger_modeswitch = Dict()
    for (action, keybinding) in keybindings
        rebugger_modeswitch[keybinding] = modeswitches[action]
    end
    rebugger_modeswitch
end

function add_keybindings(; override::Bool=false, kwargs...)
    main_repl = Base.active_repl
    history_prompt = find_prompt(main_repl.interface, LineEdit.PrefixHistoryPrompt)
    julia_prompt = find_prompt(main_repl.interface, "julia")
    rebug_prompt = find_prompt(main_repl.interface, "rebug")
    for (action, keybinding) in kwargs
        if !(action in keys(keybindings))
            error("$action is not a supported action.")
        end
        if !(keybinding isa Union{String,Vector{String}})
            error("Expected the value for $action to be a String or Vector{String}, got $keybinding instead")
        end
        if haskey(keybindings, action)
            keybindings[action] = keybinding
        end
        if action == :interpret
            LineEdit.add_nested_key!(julia_prompt.keymap_dict, keybinding, modeswitches[action], override=override)
        else
            # We need Any here because "cannot convert REPL.LineEdit.PrefixHistoryPrompt to an object of type REPL.LineEdit.Prompt"
            prompts = Any[julia_prompt, rebug_prompt]
            if action == :stacktrace push!(prompts, history_prompt) end
            for prompt in prompts
                if keybinding isa Vector
                    for kb in keybinding
                        LineEdit.add_nested_key!(prompt.keymap_dict, kb, modeswitches[action], override=override)
                    end
                else
                    LineEdit.add_nested_key!(prompt.keymap_dict, keybinding, modeswitches[action], override=override)
                end
            end
        end
    end
end

# These work only at the `rebug>` prompt
const rebugger_keys = Dict{Any,Any}(
)

## REPL commands TODO?:
## "\em" (meta-m): create REPL line that populates Main with arguments to current method
## "\eS" (meta-S): save version at REPL to file? (a little dangerous, perhaps make it configurable as to whether this is on)
## F1 is "^[OP" (showvalues?), F4 is "^[OS" (showinputs?)


enter_rebug(s) = mode_switch(s, rebug_prompt_ref[])
enter_interpret(s) = mode_switch(s, interpret_prompt_ref[])

function mode_switch(s, other_prompt)
    buf = copy(LineEdit.buffer(s))
    LineEdit.edit_clear(s)
    LineEdit.transition(s, other_prompt) do
        LineEdit.state(s, other_prompt).input_buffer = buf
    end
end

# julia_prompt = find_prompt(main_repl.interface, "julia")
# julia_prompt.keymap_dict['|'] = (s, o...) -> enter_count(s)
