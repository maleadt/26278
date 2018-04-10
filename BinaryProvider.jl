__precompile__()
module BinaryProvider
if VERSION >= v"0.7.0-DEV.3382"
    import Libdl
end
using Compat
print_cache = Dict()
function info_onchange(msg, key, location)
    local cache_val = get(print_cache, key, nothing)
    if cache_val != location
        Compat.@info(msg)
        print_cache[key] = location
    end
end
import Base: wait, merge
export OutputCollector, merge, collect_stdout, collect_stderr, tail, tee
struct LineStream
    pipe::Pipe
    lines::Vector{Tuple{Float64,String}}
    task::Task
end
function readuntil_many(s::IO, delims)
	out = IOBuffer()
    while !eof(s)
        c = read(s, Char)
        write(out, c)
        if c in delims
            break
        end
    end
    return String(take!(out))
end
function LineStream(pipe::Pipe, event::Condition)
    # We always have to close() the input half of the stream before we can
    # read() from it.  I don't know why, and this is honestly kind of annoying
    close(pipe.in)
    lines = Tuple{Float64,String}[]
    task = @async begin
        # Read lines in until we can't anymore.
        while true
            # Push this line onto our lines, then notify() the event
            line = readuntil_many(pipe, ['\n', '\r'])
            if isempty(line) && eof(pipe)
                break
            end
            push!(lines, (time(), line))
            notify(event)
        end
    end
    # Create a second task that runs after the first just to notify()
    # This ensures that anybody that's listening to the event but gated on our
    # being alive (e.g. `tee()`) can die alongside us gracefully as well.
    @async begin
        wait(task)
        notify(event)
    end
    return LineStream(pipe, lines, task)
end
function alive(s::LineStream)
    return !(s.task.state in [:done, :failed])
end
mutable struct OutputCollector
    cmd::Base.AbstractCmd
    P::Base.AbstractPipe
    stdout_linestream::LineStream
    stderr_linestream::LineStream
    event::Condition
    tee_stream::IO
    verbose::Bool
    tail_error::Bool
    done::Bool
    extra_tasks::Vector{Task}
    function OutputCollector(cmd, P, out_ls, err_ls, event, tee_stream,
                             verbose, tail_error)
        return new(cmd, P, out_ls, err_ls, event, tee_stream, verbose,
                   tail_error, false, Task[])
    end
end
function OutputCollector(cmd::Base.AbstractCmd; verbose::Bool=false,
                         tail_error::Bool=true, tee_stream::IO=Compat.stdout)
    # First, launch the command
    out_pipe = Pipe()
    err_pipe = Pipe()
    P = try
        @static if applicable(spawn, `ls`, (devnull, stdout, stderr))
            spawn(cmd, (devnull, out_pipe, err_pipe))
        else
            run(pipeline(cmd, stdin=devnull, stdout=out_pipe, stderr=err_pipe); wait=false)
        end
    catch
        Compat.@warn("Could not spawn $(cmd)")
        rethrow()
    end
    # Next, start siphoning off the first couple lines of output and error
    event = Condition()
    out_ls = LineStream(out_pipe, event)
    err_ls = LineStream(err_pipe, event)
    # Finally, wrap this up in an object so that we can merge stdout and stderr
    # back together again at the end
    self = OutputCollector(cmd, P, out_ls, err_ls, event, tee_stream,
                           verbose, tail_error)
    # If we're set as verbose, then start reading ourselves out to stdout
    if verbose
        tee(self; stream = tee_stream)
    end
    return self
end
function wait(collector::OutputCollector)
    # If we've already done this song and dance before, then don't do it again
    if !collector.done
        wait(collector.P)
        wait(collector.stdout_linestream.task)
        wait(collector.stderr_linestream.task)
        # Also fetch on any extra tasks we've jimmied onto the end of this guy
        for t in collector.extra_tasks
            wait(t)
        end
        # From this point on, we are actually done!
        collector.done = true
        # If we failed, print out the tail of the output, unless we've been
        # tee()'ing it out this whole time, but only if the user said it's okay.
        if !success(collector.P) && !collector.verbose && collector.tail_error
            our_tail = tail(collector; colored=Base.have_color)
            print(collector.tee_stream, our_tail)
        end
    end
    # Shout to the world how we've done
    return success(collector.P)
end
function merge(collector::OutputCollector; colored::Bool = false)
    # First, wait for things to be done.  No incomplete mergings here yet.
    wait(collector)
    # We copy here so that you can `merge()` more than once, if you want.
    stdout_lines = copy(collector.stdout_linestream.lines)
    stderr_lines = copy(collector.stderr_linestream.lines)
    output = IOBuffer()
    # Write out an stdout line, optionally with color, and pop off that line
    function write_line(lines, should_color, color)
        if should_color && colored
            print(output, color)
        end
        t, line = popfirst!(lines)
        print(output, line)
    end
    # These help us keep track of colorizing the output
    out_color = Base.text_colors[:default]
    err_color = Base.text_colors[:red]
    last_line_stderr = false
    # Merge stdout and stderr    
    while !isempty(stdout_lines) && !isempty(stderr_lines)
        # Figure out if stdout's timestamp is earlier than stderr's
        if stdout_lines[1][1] < stderr_lines[1][1]
            write_line(stdout_lines,  last_line_stderr, out_color)
            last_line_stderr = false
        else
            write_line(stderr_lines, !last_line_stderr, err_color)
            last_line_stderr = true
        end
    end
    # Now drain whichever one still has data within it
    while !isempty(stdout_lines)
        write_line(stdout_lines, last_line_stderr, out_color)
        last_line_stderr = false
    end
    while !isempty(stderr_lines)
        write_line(stderr_lines, !last_line_stderr, err_color)
        last_line_stderr = true
    end
    # Clear text colors at the end, if we need to
    if last_line_stderr && colored
        print(output, Base.text_colors[:default])
    end
    # Return our ill-gotten goods
    return String(take!(output))
end
function collect_stdout(collector::OutputCollector)
    return join([l[2] for l in collector.stdout_linestream.lines], "")
end
function collect_stderr(collector::OutputCollector)
    return join([l[2] for l in collector.stderr_linestream.lines], "")
end
function tail(collector::OutputCollector; len::Int = 100,
              colored::Bool = false)
    out = merge(collector; colored=colored)
    idx = length(out)
    for line_idx in 1:len
        # We can run into UnicodeError's here
        try
            idx = findprev(equalto('\n'), out, idx-1)
            # We have to check for both `nothing` or `0` for Julia 0.6
            if idx === nothing || idx == 0
                idx = 0
                break
            end
        catch
            break
        end
    end
    return out[idx+1:end]
end
function tee(c::OutputCollector; colored::Bool=Base.have_color,
             stream::IO=Compat.stdout)
    tee_task = @async begin
        out_idx = 1
        err_idx = 1
        out_lines = c.stdout_linestream.lines
        err_lines = c.stderr_linestream.lines
        # Helper function to print out the next line of stdout/stderr
        function print_next_line()
            timestr = Libc.strftime("[%T] ", time())
            # We know we have data, so figure out if it's for stdout, stderr
            # or both, and we need to choose which to print based on timestamp
            printstyled(stream, timestr; bold=true)
            if length(out_lines) >= out_idx
                if length(err_lines) >= err_idx
                    # If we've got input waiting from both lines, then output
                    # the one with the lowest capture time
                    if out_lines[out_idx][1] < err_lines[err_idx][1]
                        # Print the out line as it's older
                        print(stream, out_lines[out_idx][2])
                        out_idx += 1
                    else
                        # Print the err line as it's older
                        printstyled(stream, err_lines[err_idx][2]; color=:red)
                        print(stream)
                        err_idx += 1
                    end
                else
                    # Print the out line that is the only one waiting
                    print(stream, out_lines[out_idx][2])
                    out_idx += 1
                end
            else
                # Print the err line that is the only one waiting
                printstyled(stream, err_lines[err_idx][2]; color=:red)
                print(stream)
                err_idx += 1
            end
        end
        # First thing, wait for some input.  This avoids us trying to inspect
        # the liveliness of the linestreams before they've even started.
        wait(c.event)
        while alive(c.stdout_linestream) || alive(c.stderr_linestream)
            if length(out_lines) >= out_idx || length(err_lines) >= err_idx
                # If we have data to output, then do so
                print_next_line()
            else
                # Otherwise, wait for more input
                wait(c.event)
            end
        end
        # Drain the rest of stdout and stderr
        while length(out_lines) >= out_idx || length(err_lines) >= err_idx
            print_next_line()
        end
    end
    # Let the collector know that he might have to wait on this `tee()` to
    # finish its business as well.
    push!(c.extra_tasks, tee_task)
    return tee_task
end
export gen_download_cmd, gen_unpack_cmd, gen_package_cmd, gen_list_tarball_cmd,
       parse_tarball_listing, gen_sh_cmd, parse_7z_list, parse_tar_list,
       download_verify_unpack, download_verify, unpack
gen_download_cmd = (url::AbstractString, out_path::AbstractString) ->
    error("Call `probe_platform_engines()` before `gen_download_cmd()`")
gen_unpack_cmd = (tarball_path::AbstractString, out_path::AbstractString) ->
    error("Call `probe_platform_engines()` before `gen_unpack_cmd()`")
gen_package_cmd = (in_path::AbstractString, tarball_path::AbstractString) ->
    error("Call `probe_platform_engines()` before `gen_package_cmd()`")
gen_list_tarball_cmd = (tarball_path::AbstractString) ->
    error("Call `probe_platform_engines()` before `gen_list_tarball_cmd()`")
parse_tarball_listing = (output::AbstractString) ->
    error("Call `probe_platform_engines()` before `parse_tarball_listing()`")
gen_sh_cmd = (cmd::Cmd) ->
    error("Call `probe_platform_engines()` before `gen_sh_cmd()`")
function probe_cmd(cmd::Cmd; verbose::Bool = false)
    if verbose
        Compat.@info("Probing $(cmd.exec[1]) as a possibility...")
    end
    try
        success(cmd)
        if verbose
            Compat.@info("  Probe successful for $(cmd.exec[1])")
        end
        return true
    catch
        return false
    end
end
function probe_platform_engines!(;verbose::Bool = false)
    global gen_download_cmd, gen_list_tarball_cmd, gen_package_cmd
    global gen_unpack_cmd, parse_tarball_listing, gen_sh_cmd
    # download_engines is a list of (test_cmd, download_opts_functor)
    # The probulator will check each of them by attempting to run `$test_cmd`,
    # and if that works, will set the global download functions appropriately.
    download_engines = [
        (`curl --help`, (url, path) -> `curl -C - -\# -f -o $path -L $url`),
        (`wget --help`, (url, path) -> `wget -c -O $path $url`),
        (`fetch --help`, (url, path) -> `fetch -f $path $url`),
    ]
    # 7z is rather intensely verbose.  We also want to try running not only
    # `7z` but also a direct path to the `7z.exe` bundled with Julia on
    # windows, so we create generator functions to spit back functors to invoke
    # the correct 7z given the path to the executable:
    unpack_7z = (exe7z) -> begin
        return (tarball_path, out_path) ->
            pipeline(`$exe7z x $(tarball_path) -y -so`,
                     `$exe7z x -si -y -ttar -o$(out_path)`)
    end
    package_7z = (exe7z) -> begin
        return (in_path, tarball_path) ->
            pipeline(`$exe7z a -ttar -so a.tar "$(joinpath(".",in_path,"*"))"`,
                     `$exe7z a -si $(tarball_path)`)
    end
    list_7z = (exe7z) -> begin
        return (path) ->
            pipeline(`$exe7z x $path -so`, `$exe7z l -ttar -y -si`)
    end
    # Tar is rather less verbose, and we don't need to search multiple places
    # for it, so just rely on PATH to have `tar` available for us:
    unpack_tar = (tarball_path, out_path) ->
        `tar xf $(tarball_path) --directory=$(out_path)`
    package_tar = (in_path, tarball_path) ->
        `tar -czvf $tarball_path -C $(in_path) .`
    list_tar = (in_path) -> `tar tf $in_path`
    # compression_engines is a list of (test_cmd, unpack_opts_functor,
    # package_opts_functor, list_opts_functor, parse_functor).  The probulator
    # will check each of them by attempting to run `$test_cmd`, and if that
    # works, will set the global compression functions appropriately.
    gen_7z = (p) -> (unpack_7z(p), package_7z(p), list_7z(p), parse_7z_list)
    compression_engines = Tuple[
        (`tar --help`, unpack_tar, package_tar, list_tar, parse_tar_list),
    ]
    # sh_engines is just a list of Cmds-as-paths
    sh_engines = [
        `sh`
    ]
    # For windows, we need to tweak a few things, as the tools available differ
    @static if Compat.Sys.iswindows()
        # For download engines, we will most likely want to use powershell.
        # Let's generate a functor to return the necessary powershell magics
        # to download a file, given a path to the powershell executable
        psh_download = (psh_path) -> begin
            return (url, path) -> begin
                webclient_code = """
                [System.Net.ServicePointManager]::SecurityProtocol =
                    [System.Net.SecurityProtocolType]::Tls12;
                \$webclient = (New-Object System.Net.Webclient);
                \$webclient.DownloadFile(\"$url\", \"$path\")
                """
                replace(webclient_code, "\n" => " ")
                return `$psh_path -NoProfile -Command "$webclient_code"`
            end
        end
        # We want to search both the `PATH`, and the direct path for powershell
        psh_path = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell"
        prepend!(download_engines, [
            (`$psh_path -Help`, psh_download(psh_path))
        ])
        prepend!(download_engines, [
            (`powershell -Help`, psh_download(`powershell`))
        ])
        # We greatly prefer `7z` as a compression engine on Windows
        prepend!(compression_engines, [(`7z --help`, gen_7z("7z")...)])
        # On windows, we bundle 7z with Julia, so try invoking that directly
        exe7z = joinpath(Compat.Sys.BINDIR, "7z.exe")
        prepend!(compression_engines, [(`$exe7z --help`, gen_7z(exe7z)...)])
        # And finally, we want to look for sh as busybox as well:
        busybox = joinpath(Compat.Sys.BINDIR, "busybox.exe")
        prepend!(sh_engines, [(`$busybox sh`)])
    end
    # Allow environment override
    if haskey(ENV, "BINARYPROVIDER_DOWNLOAD_ENGINE")
        engine = ENV["BINARYPROVIDER_DOWNLOAD_ENGINE"]
        dl_ngs = filter(e -> e[1].exec[1] == engine, download_engines)
        if isempty(dl_ngs)
            all_ngs = join([d[1].exec[1] for d in download_engines], ", ")
            warn_msg  = "Ignoring BINARYPROVIDER_DOWNLOAD_ENGINE as its value "
            warn_msg *= "of `$(engine)` doesn't match any known valid engines."
            warn_msg *= " Try one of `$(all_ngs)`."
            Compat.@warn(warn_msg)
        else
            # If BINARYPROVIDER_DOWNLOAD_ENGINE matches one of our download engines,
            # then restrict ourselves to looking only at that engine
            download_engines = dl_ngs
        end
    end
    if haskey(ENV, "BINARYPROVIDER_COMPRESSION_ENGINE")
        engine = ENV["BINARYPROVIDER_COMPRESSION_ENGINE"]
        comp_ngs = filter(e -> e[1].exec[1] == engine, compression_engines)
        if isempty(comp_ngs)
            all_ngs = join([c[1].exec[1] for c in compression_engines], ", ")
            warn_msg  = "Ignoring BINARYPROVIDER_COMPRESSION_ENGINE as its "
            warn_msg *= "value of `$(engine)` doesn't match any known valid "
            warn_msg *= "engines. Try one of `$(all_ngs)`."
            Compat.@warn(warn_msg)
        else
            # If BINARYPROVIDER_COMPRESSION_ENGINE matches one of our download
            # engines, then restrict ourselves to looking only at that engine
            compression_engines = comp_ngs
        end
    end
    download_found = false
    compression_found = false
    sh_found = false
    if verbose
        Compat.@info("Probing for download engine...")
    end
    # Search for a download engine
    for (test, dl_func) in download_engines
        if probe_cmd(`$test`; verbose=verbose)
            # Set our download command generator
            gen_download_cmd = dl_func
            download_found = true
            if verbose
                Compat.@info("Found download engine $(test.exec[1])")
            end
            break
        end
    end
    if verbose
        Compat.@info("Probing for compression engine...")
    end
    # Search for a compression engine
    for (test, unpack, package, list, parse) in compression_engines
        if probe_cmd(`$test`; verbose=verbose)
            # Set our compression command generators
            gen_unpack_cmd = unpack
            gen_package_cmd = package
            gen_list_tarball_cmd = list
            parse_tarball_listing = parse
            if verbose
                Compat.@info("Found compression engine $(test.exec[1])")
            end
            compression_found = true
            break
        end
    end
    if verbose
        Compat.@info("Probing for sh engine...")
    end
    for path in sh_engines
        if probe_cmd(`$path --help`; verbose=verbose)
            gen_sh_cmd = (cmd) -> `$path -c $cmd`
            if verbose
                Compat.@info("Found sh engine $(path.exec[1])")
            end
            sh_found = true
            break
        end
    end
    # Build informative error messages in case things go sideways
    errmsg = ""
    if !download_found
        errmsg *= "No download engines found. We looked for: "
        errmsg *= join([d[1].exec[1] for d in download_engines], ", ")
        errmsg *= ". Install one and ensure it  is available on the path.\n"
    end
    if !compression_found
        errmsg *= "No compression engines found. We looked for: "
        errmsg *= join([c[1].exec[1] for c in compression_engines], ", ")
        errmsg *= ". Install one and ensure it is available on the path.\n"
    end
    if !sh_found && verbose
        Compat.@warn("No sh engines found.  Test suite will fail.")
    end
    # Error out if we couldn't find something
    if !download_found || !compression_found
        error(errmsg)
    end
end
function parse_7z_list(output::AbstractString)
    lines = [chomp(l) for l in split(output, "\n")]
    # If we didn't get anything, complain immediately
    if isempty(lines)
        return []
    end
    # Remove extraneous "\r" for windows platforms
    for idx in 1:length(lines)
        if endswith(lines[idx], '\r')
            lines[idx] = lines[idx][1:end-1]
        end
    end
    # Find index of " Name". (can't use `findfirst(generator)` until this is
    # closed: https://github.com/JuliaLang/julia/issues/16884
    header_row = find(contains(l, " Name") && contains(l, " Attr") for l in lines)[1]
    name_idx = search(lines[header_row], "Name")[1]
    attr_idx = search(lines[header_row], "Attr")[1] - 1
    # Filter out only the names of files, ignoring directories
    lines = [l[name_idx:end] for l in lines if length(l) > name_idx && l[attr_idx] != 'D']
    if isempty(lines)
        return []
    end
    # Extract within the bounding lines of ------------
    bounds = [i for i in 1:length(lines) if all([c for c in lines[i]] .== '-')]
    lines = lines[bounds[1]+1:bounds[2]-1]
    # Eliminate `./` prefix, if it exists
    for idx in 1:length(lines)
        if startswith(lines[idx], "./") || startswith(lines[idx], ".\\")
            lines[idx] = lines[idx][3:end]
        end
    end
    return lines
end
function parse_tar_list(output::AbstractString)
    lines = [chomp(l) for l in split(output, "\n")]
    # Drop empty lines and and directories
    lines = [l for l in lines if !isempty(l) && !endswith(l, '/')]
    # Eliminate `./` prefix, if it exists
    for idx in 1:length(lines)
        if startswith(lines[idx], "./") || startswith(lines[idx], ".\\")
            lines[idx] = lines[idx][3:end]
        end
    end
    return lines
end
function download(url::AbstractString, dest::AbstractString;
                  verbose::Bool = false)
    download_cmd = gen_download_cmd(url, dest)
    if verbose
        Compat.@info("Downloading $(url) to $(dest)...")
    end
    oc = OutputCollector(download_cmd; verbose=verbose)
    try
        if !wait(oc)
            error()
        end
    catch e
        if isa(e, InterruptException)
            rethrow()
        end
        error("Could not download $(url) to $(dest)")
    end
end
function download_verify(url::AbstractString, hash::AbstractString,
                         dest::AbstractString; verbose::Bool = false,
                         force::Bool = false, quiet_download::Bool = false)
    # Whether the file existed in the first place
    file_existed = false
    if isfile(dest)
        file_existed = true
        if verbose
            info_onchange(
                "Destination file $(dest) already exists, verifying...",
                "download_verify_$(dest)",
                @__LINE__,
            )
        end
        # verify download, if it passes, return happy.  If it fails, (and
        # `force` is `true`, re-download!)
        try
            verify(dest, hash; verbose=verbose)
            return true
        catch e
            if isa(e, InterruptException)
                rethrow()
            end
            if !force
                rethrow()
            end
            if verbose
                info_onchange(
                    "Verification failed, re-downloading...",
                    "download_verify_$(dest)",
                    @__LINE__,
                )
            end
        end
    end
    # Make sure the containing folder exists
    mkpath(dirname(dest))
    try
        # Download the file, optionally continuing
        download(url, dest; verbose=verbose || !quiet_download)
        verify(dest, hash; verbose=verbose)
    catch e
        if isa(e, InterruptException)
            rethrow()
        end
        # If the file already existed, it's possible the initially downloaded chunk
        # was bad.  If verification fails after downloading, auto-delete the file
        # and start over from scratch.
        if file_existed
            if verbose
                Compat.@info("Continued download didn't work, restarting from scratch")
            end
            rm(dest; force=true)
            # Download and verify from scratch
            download(url, dest; verbose=verbose || !quiet_download)
            verify(dest, hash; verbose=verbose)
        else
            # If it didn't verify properly and we didn't resume, something is
            # very wrong and we must complain mightily.
            rethrow()
        end
    end
    # If the file previously existed, this means we removed it (due to `force`)
    # and redownloaded, so return `false`.  If it didn't exist, then this means
    # that we successfully downloaded it, so return `true`.
    return !file_existed
end
function package(src_dir::AbstractString, tarball_path::AbstractString;
                  verbose::Bool = false)
    # For now, use environment variables to set the gzip compression factor to
    # level 9, eventually there will be new enough versions of tar everywhere
    # to use -I 'gzip -9', or even to switch over to .xz files.
    withenv("GZIP" => "-9") do
        oc = OutputCollector(gen_package_cmd(src_dir, tarball_path); verbose=verbose)
        try
            if !wait(oc)
                error()
            end
        catch e
            if isa(e, InterruptException)
                rethrow()
            end
            error("Could not package $(src_dir) into $(tarball_path)")
        end
    end
end
function unpack(tarball_path::AbstractString, dest::AbstractString;
                verbose::Bool = false)
    # unpack into dest
    mkpath(dest)
    oc = OutputCollector(gen_unpack_cmd(tarball_path, dest); verbose=verbose)
    try 
        if !wait(oc)
            error()
        end
    catch e
        if isa(e, InterruptException)
            rethrow()
        end
        error("Could not unpack $(tarball_path) into $(dest)")
    end
end
function download_verify_unpack(url::AbstractString,
                                hash::AbstractString,
                                dest::AbstractString;
                                tarball_path = nothing,
                                force::Bool = false,
                                verbose::Bool = false)
    # First, determine whether we should keep this tarball around
    remove_tarball = false
    if tarball_path === nothing
        remove_tarball = true
        tarball_path = "$(tempname())-download.tar.gz"
    end
    # Download the tarball; if it already existed and we needed to remove it
    # then we should remove the unpacked path as well
    should_delete = !download_verify(url, hash, tarball_path;
                                     force=force, verbose=verbose)
    if should_delete
        if verbose
            Compat.@info("Removing dest directory $(dest) as source tarball changed")
        end
        rm(dest; recursive=true, force=true)
    end
    # If the destination path already exists, don't bother to unpack
    if isdir(dest)
        if verbose
            Compat.@info("Destination directory $(dest) already exists, returning")
        end
        return
    end
    try
        if verbose
            Compat.@info("Unpacking $(tarball_path) into $(dest)...")
        end
        unpack(tarball_path, dest; verbose=verbose)
    finally
        if remove_tarball
            rm(tarball_path)
        end
    end
end
export supported_platforms, platform_key, platform_dlext, valid_dl_path,
       arch, wordsize, triplet, Platform, UnknownPlatform, Linux, MacOS,
       Windows, FreeBSD
abstract type Platform end
struct UnknownPlatform <: Platform
end
struct Linux <: Platform
    arch::Symbol
    libc::Symbol
    abi::Symbol
    function Linux(arch::Symbol, libc::Symbol=:glibc,
                                 abi::Symbol=:default_abi)
        if !in(arch, [:i686, :x86_64, :aarch64, :powerpc64le, :armv7l])
            throw(ArgumentError("Unsupported architecture '$arch' for Linux"))
        end
        # The default libc on Linux is glibc
        if libc === :blank_libc
            libc = :glibc
        end
        if !in(libc, [:glibc, :musl])
            throw(ArgumentError("Unsupported libc '$libc' for Linux"))
        end
        # The default abi on Linux is blank, so map over to that by default,
        # except on armv7l, where we map it over to :eabihf
        if abi === :default_abi
            if arch != :armv7l
                abi = :blank_abi
            else
                abi = :eabihf
            end
        end
        if !in(abi, [:eabihf, :blank_abi])
            throw(ArgumentError("Unsupported abi '$abi' for Linux"))
        end
        # If we're constructing for armv7l, we MUST have the eabihf abi
        if arch == :armv7l && abi != :eabihf
            throw(ArgumentError("armv7l Linux must use eabihf, not '$abi'"))
        end
        # ...and vice-versa
        if arch != :armv7l && abi == :eabihf
            throw(ArgumentError("eabihf Linux is only on armv7l, not '$arch'!"))
        end
        return new(arch, libc, abi)
    end
end
struct MacOS <: Platform
    arch::Symbol
    libc::Symbol
    abi::Symbol
    # Provide defaults for everything because there's really only one MacOS
    # target right now.  Maybe someday iOS.  :fingers_crossed:
    function MacOS(arch::Symbol=:x86_64, libc::Symbol=:blank_libc,
                                         abi=:blank_abi)
        if arch !== :x86_64
            throw(ArgumentError("Unsupported architecture '$arch' for macOS"))
        end
        if libc !== :blank_libc
            throw(ArgumentError("Unsupported libc '$libc' for macOS"))
        end
        if abi !== :blank_abi
            throw(ArgumentError("Unsupported abi '$abi' for macOS"))
        end
        return new(arch, libc, abi)
    end
end
struct Windows <: Platform
    arch::Symbol
    libc::Symbol
    abi::Symbol
    function Windows(arch::Symbol, libc::Symbol=:blank_libc,
                                   abi::Symbol=:blank_abi)
        if !in(arch, [:i686, :x86_64])
            throw(ArgumentError("Unsupported architecture '$arch' for Windows"))
        end
        # We only support the one libc/abi on Windows, so no need to play
        # around with "default" values.
        if libc !== :blank_libc
            throw(ArgumentError("Unsupported libc '$libc' for Windows"))
        end
        if abi !== :blank_abi
            throw(ArgumentError("Unsupported abi '$abi' for Windows"))
        end
        return new(arch, libc, abi)
    end
end
struct FreeBSD <: Platform
    arch::Symbol
    libc::Symbol
    abi::Symbol
    function FreeBSD(arch::Symbol, libc::Symbol=:blank_libc,
                                   abi::Symbol=:default_abi)
        if !in(arch, [:i686, :x86_64, :aarch64, :powerpc64le, :armv7l])
            throw(ArgumentError("Unsupported architecture '$arch' for FreeBSD"))
        end
        # The only libc we support on FreeBSD is the blank libc
        if libc !== :blank_libc
            throw(ArgumentError("Unsupported libc '$libc' for FreeBSD"))
        end
        # The default abi on FreeBSD is blank, execpt on armv7l
        if abi === :default_abi
            if arch != :armv7l
                abi = :blank_abi
            else
                abi = :eabihf
            end
        end
        if !in(abi, [:eabihf, :blank_abi])
            throw(ArgumentError("Unsupported abi '$abi' for FreeBSD"))
        end
        # If we're constructing for armv7l, we MUST have the eabihf abi
        if arch == :armv7l && abi != :eabihf
            throw(ArgumentError("armv7l FreeBSD must use eabihf, no '$abi'"))
        end
        # ...and vice-versa
        if arch != :armv7l && abi == :eabihf
            throw(ArgumentError("eabihf FreeBSD is only on armv7l, not '$arch'!"))
        end
        return new(arch, libc, abi)
    end
end
arch(p::Platform) = p.arch
arch(u::UnknownPlatform) = :unknown
libc(p::Platform) = p.libc
libc(u::UnknownPlatform) = :unknown
abi(p::Platform) = p.abi
abi(u::UnknownPlatform) = :unknown
wordsize(p::Platform) = (arch(p) === :i686 || arch(p) === :armv7l) ? 32 : 64
wordsize(u::UnknownPlatform) = 0
triplet(w::Windows) = string(arch_str(w), "-w64-mingw32")
triplet(m::MacOS) = string(arch_str(m), "-apple-darwin14")
triplet(l::Linux) = string(arch_str(l), "-linux", libc_str(l), abi_str(l))
triplet(f::FreeBSD) = string(arch_str(f), "-unknown-freebsd11.1", libc_str(f), abi_str(f))
triplet(u::UnknownPlatform) = "unknown-unknown-unknown"
arch_str(p::Platform) = (arch(p) == :armv7l) ? "arm" : "$(arch(p))"
function libc_str(p::Platform)
    if libc(p) == :blank_libc
        return ""
    elseif libc(p) == :glibc
        return "-gnu"
    else
        return "-$(libc(p))"
    end
end
abi_str(p::Platform) = (abi(p) == :blank_abi) ? "" : "$(abi(p))"
function supported_platforms()
    return [
        Linux(:i686),
        Linux(:x86_64),
        Linux(:aarch64),
        Linux(:armv7l),
        Linux(:powerpc64le),
        MacOS(),
        Windows(:i686),
        Windows(:x86_64),
    ]
end
Compat.Sys.isapple(p::Platform) = p isa MacOS
Compat.Sys.islinux(p::Platform) = p isa Linux
Compat.Sys.iswindows(p::Platform) = p isa Windows
Compat.Sys.isbsd(p::Platform) = (p isa FreeBSD) || (p isa MacOS)
function platform_key(machine::AbstractString = Sys.MACHINE)
    # We're going to build a mondo regex here to parse everything:
    arch_mapping = Dict(
        :x86_64 => "x86_64",
        :i686 => "i\\d86",
        :aarch64 => "aarch64",
        :armv7l => "arm(v7l)?",
        :powerpc64le => "p(ower)?pc64le",
    )
    platform_mapping = Dict(
        :darwin => "-apple-darwin\\d*",
        :freebsd => "-(.*-)?freebsd[\\d\\.]*",
        :mingw32 => "-w64-mingw32",
        :linux => "-(.*-)?linux",
    )
    libc_mapping = Dict(
        :blank_libc => "",
        :glibc => "-gnu",
        :musl => "-musl",
    )
    abi_mapping = Dict(
        :blank_abi => "",
        :eabihf => "eabihf",
    )
    # Helper function to collapse dictionary of mappings down into a regex of
    # named capture groups joined by "|" operators
    c(mapping) = string("(",join(["(?<$k>$v)" for (k, v) in mapping], "|"), ")")
    triplet_regex = Regex(string(
        c(arch_mapping),
        c(platform_mapping),
        c(libc_mapping),
        c(abi_mapping),
    ))
    m = match(triplet_regex, machine)
    if m != nothing
        # Helper function to find the single named field within the giant regex
        # that is not `nothing` for each mapping we give it.
        get_field(m, mapping) = begin
            for k in keys(mapping)
                if m[k] != nothing
                   return k
                end
            end
        end
        # Extract the information we're interested in:
        arch = get_field(m, arch_mapping)
        platform = get_field(m, platform_mapping)
        libc = get_field(m, libc_mapping)
        abi = get_field(m, abi_mapping)
        # First, figure out what platform we're dealing with, then sub that off
        # to the appropriate constructor.  All constructors take in (arch, libc,
        # abi)  but they will throw errors on trouble, so we catch those and
        # return the value UnknownPlatform() here to be nicer to client code.
        try
            if platform == :darwin
                return MacOS(arch, libc, abi)
            elseif platform == :mingw32
                return Windows(arch, libc, abi)
            elseif platform == :freebsd
                return FreeBSD(arch, libc, abi)
            elseif platform == :linux
                return Linux(arch, libc, abi)
            end
        end
    end
    warn("Platform `$(machine)` is not an officially supported platform")
    return UnknownPlatform()
end
platform_dlext(l::Linux) = "so"
platform_dlext(f::FreeBSD) = "so"
platform_dlext(m::MacOS) = "dylib"
platform_dlext(w::Windows) = "dll"
platform_dlext(u::UnknownPlatform) = "unknown"
platform_dlext() = platform_dlext(platform_key())
function valid_dl_path(path::AbstractString, platform::Platform)
    dlext_regexes = Dict(
        # On Linux, libraries look like `libnettle.so.6.3.0`
        "so" => r"^(.*).so(\.[\d]+){0,3}$",
        # On OSX, libraries look like `libnettle.6.3.dylib`
        "dylib" => r"^(.*).dylib$",
        # On Windows, libraries look like `libnettle-6.dylib`
        "dll" => r"^(.*).dll$"
    )
    # Given a platform, find the dlext regex that matches it
    dlregex = dlext_regexes[platform_dlext(platform)]
    # Return whether or not that regex matches the basename of the given path
    return ismatch(dlregex, basename(path))
end
import Base: convert, joinpath, show
using SHA
export Prefix, bindir, libdir, includedir, logdir, activate, deactivate,
       extract_platform_key, install, uninstall, manifest_from_url,
       manifest_for_file, list_tarball_files, verify, temp_prefix, package
function safe_isfile(path)
    try
        return isfile(path)
    catch e
        if typeof(e) <: Base.UVError && e.code == Base.UV_EINVAL
            return false
        end
        rethrow(e)
    end
end
function temp_prefix(func::Function)
    # Helper function to create a docker-mountable temporary directory
    function _tempdir()
        @static if Compat.Sys.isapple()
            # Docker, on OSX at least, can only mount from certain locations by
            # default, so we ensure all our temporary directories live within
            # those locations so that they are accessible by Docker.
            return "/tmp"
        else
            return tempdir()
        end
    end
    mktempdir(_tempdir()) do path
        prefix = Prefix(path)
        # Run the user function
        func(prefix)
    end
end
global_prefix = nothing
struct Prefix
    path::String
    """
        Prefix(path::AbstractString)
    A `Prefix` represents a binary installation location.  There is a default
    global `Prefix` (available at `BinaryProvider.global_prefix`) that packages
    are installed into by default, however custom prefixes can be created
    trivially by simply constructing a `Prefix` with a given `path` to install
    binaries into, likely including folders such as `bin`, `lib`, etc...
    """
    function Prefix(path::AbstractString)
        # Canonicalize immediately, create the overall prefix, then return
        path = abspath(path)
        mkpath(path)
        return new(path)
    end
end
joinpath(prefix::Prefix, args...) = joinpath(prefix.path, args...)
joinpath(s::AbstractString, prefix::Prefix, args...) = joinpath(s, prefix.path, args...)
convert(::Type{AbstractString}, prefix::Prefix) = prefix.path
show(io::IO, prefix::Prefix) = show(io, "Prefix($(prefix.path))")
function split_PATH(PATH::AbstractString = ENV["PATH"])
    @static if Compat.Sys.iswindows()
        return split(PATH, ";")
    else
        return split(PATH, ":")
    end
end
function join_PATH(paths::Vector{S}) where S<:AbstractString
    @static if Compat.Sys.iswindows()
        return join(paths, ";")
    else
        return join(paths, ":")
    end
end
function bindir(prefix::Prefix)
    return joinpath(prefix, "bin")
end
function libdir(prefix::Prefix)
    @static if Compat.Sys.iswindows()
        return joinpath(prefix, "bin")
    else
        return joinpath(prefix, "lib")
    end
end
function includedir(prefix::Prefix)
    return joinpath(prefix, "include")
end
function logdir(prefix::Prefix)
    return joinpath(prefix, "logs")
end
function activate(prefix::Prefix)
    # Add to PATH
    paths = split_PATH()
    if !(bindir(prefix) in paths)
        prepend!(paths, [bindir(prefix)])
    end
    ENV["PATH"] = join_PATH(paths)
    # Add to DL_LOAD_PATH
    if !(libdir(prefix) in Libdl.DL_LOAD_PATH)
        prepend!(Libdl.DL_LOAD_PATH, [libdir(prefix)])
    end
    return nothing
end
function activate(func::Function, prefix::Prefix)
    activate(prefix)
    func()
    deactivate(prefix)
end
function deactivate(prefix::Prefix)
    # Remove from PATH
    paths = split_PATH()
    filter!(p -> p != bindir(prefix), paths)
    ENV["PATH"] = join_PATH(paths)
    # Remove from DL_LOAD_PATH
    filter!(p -> p != libdir(prefix), Libdl.DL_LOAD_PATH)
    return nothing
end
function extract_platform_key(path::AbstractString)
    if endswith(path, ".tar.gz")
        path = path[1:end-7]
    end
    idx = rsearch(path, '.')
    if idx == 0
        Compat.@warn("Could not extract the platform key of $(path); continuing...")
        return platform_key()
    end
    return platform_key(path[idx+1:end])
end
function install(tarball_url::AbstractString,
                 hash::AbstractString;
                 prefix::Prefix = global_prefix,
                 force::Bool = false,
                 ignore_platform::Bool = false,
                 verbose::Bool = false)
    # If we're not ignoring the platform, get the platform key from the tarball
    # and complain if it doesn't match the platform we're currently running on
    if !ignore_platform
        try
            platform = extract_platform_key(tarball_url)
            # Check if we had a well-formed platform that just doesn't match
            if platform_key() != platform
                msg = replace(strip("""
                Will not install a tarball of platform $(triplet(platform)) on
                a system of platform $(triplet(platform_key())) unless
                `ignore_platform` is explicitly set to `true`.
                """), "\n" => " ")
                throw(ArgumentError(msg))
            end
        catch e
            # Check if we had a malformed platform
            if isa(e, ArgumentError)
                msg = "$(e.msg), override this by setting `ignore_platform`"
                throw(ArgumentError(msg))
            else
                # Something else went wrong, pass it along
                rethrow(e)
            end
        end
    end
    # Create the downloads directory if it does not already exist
    tarball_path = joinpath(prefix, "downloads", basename(tarball_url))
    try mkpath(dirname(tarball_path)) end
    # Check to see if we're "installing" from a file
    if safe_isfile(tarball_url)
        # If we are, just verify it's already downloaded properly
        tarball_path = tarball_url
        verify(tarball_path, hash; verbose=verbose)
    else
        # If not, actually download it
        download_verify(tarball_url, hash, tarball_path;
                        force=force, verbose=verbose)
    end
    if verbose
        Compat.@info("Installing $(tarball_path) into $(prefix.path)")
    end
    # First, get list of files that are contained within the tarball
    file_list = list_tarball_files(tarball_path)
    # Check to see if any files are already present
    for file in file_list
        if isfile(joinpath(prefix, file))
            if !force
                msg  = "$(file) already exists and would be overwritten while "
                msg *= "installing $(basename(tarball_path))\n"
                msg *= "Will not overwrite unless `force = true` is set."
                error(msg)
            else
                if verbose
                    Compat.@info("$(file) already exists, force-removing")
                end
                rm(file; force=true)
            end
        end
    end
    # Unpack the tarball into prefix
    unpack(tarball_path, prefix.path; verbose=verbose)
    # Save installation manifest
    manifest_path = manifest_from_url(tarball_path, prefix=prefix)
    mkpath(dirname(manifest_path))
    open(manifest_path, "w") do f
        write(f, join(file_list, "\n"))
    end
    return true
end
function uninstall(manifest::AbstractString;
                   verbose::Bool = false)
    # Complain if this manifest file doesn't exist
    if !isfile(manifest)
        error("Manifest path $(manifest) does not exist")
    end
    prefix_path = dirname(dirname(manifest))
    if verbose
        relmanipath = relpath(manifest, prefix_path)
        Compat.@info("Removing files installed by $(relmanipath)")
    end
    # Remove every file listed within the manifest file
    for path in [chomp(l) for l in readlines(manifest)]
        delpath = joinpath(prefix_path, path)
        if !isfile(delpath) && !islink(delpath)
            if verbose
                Compat.@info("  $delpath does not exist, but ignoring")
            end
        else
            if verbose
                delrelpath = relpath(delpath, prefix_path)
                Compat.@info("  $delrelpath removed")
            end
            rm(delpath; force=true)
            # Last one out, turn off the lights (cull empty directories,
            # but only if they're not our prefix)
            deldir = abspath(dirname(delpath))
            if isempty(readdir(deldir)) && deldir != abspath(prefix_path)
                if verbose
                    delrelpath = relpath(deldir, prefix_path)
                    Compat.@info("  Culling empty directory $delrelpath")
                end
                rm(deldir; force=true, recursive=true)
            end
        end
    end
    if verbose
        Compat.@info("  $(relmanipath) removed")
    end
    rm(manifest; force=true)
    return true
end
function manifest_from_url(url::AbstractString;
                           prefix::Prefix = global_prefix())
    # Given an URL, return an autogenerated manifest name
    return joinpath(prefix, "manifests", basename(url)[1:end-7] * ".list")
end
function manifest_for_file(path::AbstractString;
                           prefix::Prefix = global_prefix)
    if !isfile(path)
        error("File $(path) does not exist")
    end
    search_path = relpath(path, prefix.path)
    if startswith(search_path, "..")
        error("Cannot search for paths outside of the given Prefix!")
    end
    manidir = joinpath(prefix, "manifests")
    for fname in [f for f in readdir(manidir) if endswith(f, ".list")]
        manifest_path = joinpath(manidir, fname)
        if search_path in [chomp(l) for l in readlines(manifest_path)]
            return manifest_path
        end
    end
    error("Could not find $(search_path) in any manifest files")
end
function list_tarball_files(path::AbstractString; verbose::Bool = false)
    if !isfile(path)
        error("Tarball path $(path) does not exist")
    end
    # Run the listing command, then parse the output
    oc = OutputCollector(gen_list_tarball_cmd(path); verbose=verbose)
    try
        if !wait(oc)
            error()
        end
    catch
        error("Could not list contents of tarball $(path)")
    end
    return parse_tarball_listing(collect_stdout(oc))
end
function verify(path::AbstractString, hash::AbstractString; verbose::Bool = false,
                report_cache_status::Bool = false)
    if length(hash) != 64
        msg  = "Hash must be 256 bits (64 characters) long, "
        msg *= "given hash is $(length(hash)) characters long"
        error(msg)
    end
    # Fist, check to see if the hash cache is consistent
    hash_path = "$(path).sha256"
    status = :hash_consistent
    # First, it must exist
    if isfile(hash_path)
        # Next, it must contain the same hash as what we're verifying against
        if read(hash_path, String) == hash
            # Next, it must be no older than the actual path
            if stat(hash_path).mtime >= stat(path).mtime
                # If all of that is true, then we're good!
                if verbose
                    info_onchange(
                        "Hash cache is consistent, returning true",
                        "verify_$(hash_path)",
                        @__LINE__,
                    )
                end
                status = :hash_cache_consistent
                # If we're reporting our status, then report it!
                if report_cache_status
                    return true, status
                else
                    return true
                end
            else
                if verbose
                    info_onchange(
                        "File has been modified, hash cache invalidated",
                        "verify_$(hash_path)",
                        @__LINE__,
                    )
                end
                status = :file_modified
            end
        else
            if verbose
                info_onchange(
                    "Verification hash mismatch, hash cache invalidated",
                    "verify_$(hash_path)",
                    @__LINE__,
                )
            end
            status = :hash_cache_mismatch
        end
    else
        if verbose
            info_onchange(
                "No hash cache found",
                "verify_$(hash_path)",
                @__LINE__,
            )
        end
        status = :hash_cache_missing
    end
    open(path) do file
        calc_hash = bytes2hex(sha256(file))
        if verbose
            info_onchange(
                "Calculated hash $calc_hash for file $path",
                "hash_$(hash_path)",
                @__LINE__,
            )
        end
        if calc_hash != hash
            msg  = "Hash Mismatch!\n"
            msg *= "  Expected sha256:   $hash\n"
            msg *= "  Calculated sha256: $calc_hash"
            error(msg)
        end
    end
    # Save a hash cache if everything worked out fine
    open(hash_path, "w") do file
        write(file, hash)
    end
    if report_cache_status
        return true, status
    else
        return true
    end
end
function package(prefix::Prefix,
                 tarball_base::AbstractString;
                 platform::Platform = platform_key(),
                 verbose::Bool = false,
                 force::Bool = false)
    # First calculate the output path given our tarball_base and platform
    out_path = try
        "$(tarball_base).$(triplet(platform)).tar.gz"
    catch
        error("Platform key `$(platform)` not recognized")
    end
    if isfile(out_path)
        if force
            if verbose
                Compat.@info("$(out_path) already exists, force-overwriting...")
            end
            rm(out_path; force=true)
        else
            msg = replace(strip("""
            $(out_path) already exists, refusing to package into it without
            `force` being set to `true`.
            """), "\n" => " ")
            error(msg)
        end
    end
    # Package `prefix.path` into the tarball contained at to `out_path`
    package(prefix.path, out_path; verbose=verbose)
    # Also spit out the hash of the archive file
    hash = open(out_path, "r") do f
        return bytes2hex(sha256(f))
    end
    if verbose
        Compat.@info("SHA256 of $(basename(out_path)): $(hash)")
    end
    return out_path, hash
end
export Product, LibraryProduct, FileProduct, ExecutableProduct, satisfied,
       locate, write_deps_file, variable_name
import Base: repr
abstract type Product end
function satisfied(p::Product; platform::Platform = platform_key(),
                               verbose::Bool = false)
    return locate(p; platform=platform, verbose=verbose) != nothing
end
function variable_name(p::Product)
    return string(p.variable_name)
end
struct LibraryProduct <: Product
    dir_path::String
    libnames::Vector{String}
    variable_name::Symbol
    prefix::Union{Prefix, Nothing}
    """
        LibraryProduct(prefix::Prefix, libname::AbstractString,
                       varname::Symbol)
    Declares a `LibraryProduct` that points to a library located within the
    `libdir` of the given `Prefix`, with a name containing `libname`.  As an
    example, given that `libdir(prefix)` is equal to `usr/lib`, and `libname`
    is equal to `libnettle`, this would be satisfied by the following paths:
        usr/lib/libnettle.so
        usr/lib/libnettle.so.6
        usr/lib/libnettle.6.dylib
        usr/lib/libnettle-6.dll
    Libraries matching the search pattern are rejected if they are not
    `dlopen()`'able.
    """
    function LibraryProduct(prefix::Prefix, libname::AbstractString,
                            varname::Symbol)
        return LibraryProduct(prefix, [libname], varname)
    end
    function LibraryProduct(prefix::Prefix, libnames::Vector{S},
                            varname::Symbol) where {S <: AbstractString}
        return new(libdir(prefix), libnames, varname, prefix)
    end
    """
        LibraryProduct(dir_path::AbstractString, libname::AbstractString,
                       varname::Symbol)
    For finer-grained control over `LibraryProduct` locations, you may directly
    pass in the `dir_path` instead of auto-inferring it from `libdir(prefix)`.
    """
    function LibraryProduct(dir_path::AbstractString, libname::AbstractString,
                            varname::Symbol)
        return LibraryProduct(dir_path, [libname], varname)
    end
    function LibraryProduct(dir_path::AbstractString, libnames::Vector{S},
                            varname::Symbol) where {S <: AbstractString}
       return new(dir_path, libnames, varname, nothing)
    end
end
function repr(p::LibraryProduct)
    libnames = repr(p.libnames)
    varname = repr(p.variable_name)
    if p.prefix === nothing
        return "LibraryProduct($(repr(p.dir_path)), $(libnames), $(varname))"
    else
        return "LibraryProduct(prefix, $(libnames), $(varname))"
    end
end
function locate(lp::LibraryProduct; verbose::Bool = false,
                platform::Platform = platform_key())
    if !isdir(lp.dir_path)
        if verbose
            Compat.@info("Directory $(lp.dir_path) does not exist!")
        end
        return nothing
    end
    for f in readdir(lp.dir_path)
        # Skip any names that aren't a valid dynamic library for the given
        # platform (note this will cause problems if something compiles a `.so`
        # on OSX, for instance)
        if !valid_dl_path(f, platform)
            continue
        end
        if verbose
            Compat.@info("Found a valid dl path $(f) while looking for $(join(lp.libnames, ", "))")
        end
        # If we found something that is a dynamic library, let's check to see
        # if it matches our libname:
        for libname in lp.libnames
            if startswith(basename(f), libname)
                dl_path = abspath(joinpath(lp.dir_path), f)
                if verbose
                    Compat.@info("$(dl_path) matches our search criteria of $(libname)")
                end
                # If it does, try to `dlopen()` it if the current platform is good
                if platform == platform_key()
                    hdl = Libdl.dlopen_e(dl_path)
                    if hdl == C_NULL
                        if verbose
                            Compat.@info("$(dl_path) cannot be dlopen'ed")
                        end
                    else
                        # Hey!  It worked!  Yay!
                        Libdl.dlclose(hdl)
                        return dl_path
                    end
                else
                    # If the current platform doesn't match, then just trust in our
                    # cross-compilers and go with the flow
                    return dl_path
                end
            end
        end
    end
    if verbose
        Compat.@info("Could not locate $(join(lp.libnames, ", ")) inside $(lp.dir_path)")
    end
    return nothing
end
struct ExecutableProduct <: Product
    path::AbstractString
    variable_name::Symbol
    prefix::Union{Prefix, Nothing}
    """
    `ExecutableProduct(prefix::Prefix, binname::AbstractString,
                       varname::Symbol)`
    Declares an `ExecutableProduct` that points to an executable located within
    the `bindir` of the given `Prefix`, named `binname`.
    """
    function ExecutableProduct(prefix::Prefix, binname::AbstractString,
                               varname::Symbol)
        return new(joinpath(bindir(prefix), binname), varname, prefix)
    end
    """
    `ExecutableProduct(binpath::AbstractString, varname::Symbol)`
    For finer-grained control over `ExecutableProduct` locations, you may directly
    pass in the full `binpath` instead of auto-inferring it from `bindir(prefix)`.
    """
    function ExecutableProduct(binpath::AbstractString, varname::Symbol)
        return new(binpath, varname, nothing)
    end
end
function repr(p::ExecutableProduct)
    varname = repr(p.variable_name)
    if p.prefix === nothing
        return "ExecutableProduct($(repr(p.path)), $(varname))"
    else
        rp = relpath(p.path, bindir(p.prefix))
        return "ExecutableProduct(prefix, $(repr(rp)), $(varname))"
    end
end
function locate(ep::ExecutableProduct; platform::Platform = platform_key(),
                verbose::Bool = false)
    # On windows, we always slap an .exe onto the end if it doesn't already
    # exist, as Windows won't execute files that don't have a .exe at the end.
    path = if platform isa Windows && !endswith(ep.path, ".exe")
        "$(ep.path).exe"
    else
        ep.path
    end
    if !isfile(path)
        if verbose
            Compat.@info("$(ep.path) does not exist, reporting unsatisfied")
        end
        return nothing
    end
    # If the file is not executable, fail out (unless we're on windows since
    # windows doesn't honor these permissions on its filesystems)
    @static if !Compat.Sys.iswindows()
        if uperm(path) & 0x1 == 0
            if verbose
                Compat.@info("$(path) is not executable, reporting unsatisfied")
            end
            return nothing
        end
    end
    return path
end
struct FileProduct <: Product
    path::AbstractString
    variable_name::Symbol
    prefix::Union{Prefix, Nothing}
    """
        FileProduct(prefix::Prefix, relative_path::AbstractString,
                                    varname::Symbol)`
    Declares a `FileProduct` that points to a file located relative to a the
    root of a `Prefix`.
    """
    function FileProduct(prefix::Prefix, relative_path::AbstractString,
                                         varname::Symbol)
        file_path = joinpath(prefix.path, relative_path)
        return new(file_path, varname, prefix)
    end
    """
        FileProduct(file_path::AbstractString, varname::Symbol)
    For finer-grained control over `FileProduct` locations, you may directly
    pass in the full `file_pathpath` instead of defining it in reference to
    a root `Prefix`.
    """
    function FileProduct(file_path::AbstractString, varname::Symbol)
        return new(file_path, varname, nothing)
    end
end
function repr(p::FileProduct)
    varname = repr(p.variable_name)
    if p.prefix === nothing
        return "FileProduct($(repr(p.path)), $(varname))"
    else
        rp = relpath(p.path, p.prefix.path)
        return "FileProduct(prefix, $(repr(rp)), $(varname))"
    end
end
function locate(fp::FileProduct; platform::Platform = platform_key(),
                                 verbose::Bool = false)
    if isfile(fp.path)
        if verbose
            Compat.@info("FileProduct $(fp.path) does not exist")
        end
        return fp.path
    end
    return nothing
end
function write_deps_file(depsjl_path::AbstractString, products::Vector{P};
                         verbose::Bool=false) where {P <: Product}
    # helper function to escape paths
    escape_path = path -> replace(path, "\\" => "\\\\")
    # Grab the package name as the name of the top-level directory of a package
    package_name = basename(dirname(dirname(depsjl_path)))
    # We say this a couple of times
    rebuild = strip("""
    Please re-run Pkg.build(\\\"$(package_name)\\\"), and restart Julia.
    """)
    # Begin by ensuring that we can satisfy every product RIGHT NOW
    for p in products
        if !satisfied(p; verbose=verbose)
            error("$p is not satisfied, cannot generate deps.jl!")
        end
    end
    # If things look good, let's generate the `deps.jl` file
    open(depsjl_path, "w") do depsjl_file
        # First, dump the preamble
        println(depsjl_file, strip("""
        ## This file autogenerated by BinaryProvider.write_deps_file().
        ## Do not edit.
        ##
        ## Include this file within your main top-level source, and call
        ## `check_deps()` from within your module's `__init__()` method
        """))
        # Next, spit out the paths of all our products
        for product in products
            # Escape the location so that e.g. Windows platforms are happy with
            # the backslashes in a string literal
            product_path = locate(product, platform=platform_key(),
                                           verbose=verbose)
            product_path = relpath(product_path, dirname(depsjl_path))
            product_path = escape_path(product_path)
            vp = variable_name(product)
            println(depsjl_file, strip("""
            const $(vp) = joinpath(dirname(@__FILE__), \"$(product_path)\")
            """))
        end
        # Next, generate a function to check they're all on the up-and-up
        println(depsjl_file, "function check_deps()")
        for product in products
            varname = variable_name(product)
            # Add a `global $(name)`
            println(depsjl_file, "    global $(varname)");
            # Check that any file exists
            println(depsjl_file, """
                if !isfile($(varname))
                    error("\$($(varname)) does not exist, $(rebuild)")
                end
            """)
            # For Library products, check that we can dlopen it:
            if typeof(product) <: LibraryProduct
                println(depsjl_file, """
                    if Libdl.dlopen_e($(varname)) == C_NULL
                        error("\$($(varname)) cannot be opened, $(rebuild)")
                    end
                """)
            end
        end
        # If any of the products are `ExecutableProduct`s, we need to add Julia's
        # library directory onto the end of {DYLD,LD}_LIBRARY_PATH
        @static if !Compat.Sys.iswindows()
            if any(p isa ExecutableProduct for p in products)
                dllist = Sys.Libdl.dllist()
                libjulia = filter(x -> contains(x, "libjulia"), dllist)[1]
                julia_libdir = repr(joinpath(dirname(libjulia), "julia"))
                envvar_name = @static if Compat.Sys.isapple()
                    "DYLD_LIBRARY_PATH"
                else Compat.Sys.islinux()
                    "LD_LIBRARY_PATH"
                end
                envvar_name = repr(envvar_name)
                println(depsjl_file, """
                    libpaths = split(get(ENV, $(envvar_name), ""), ":")
                    if !($(julia_libdir) in libpaths)
                        push!(libpaths, $(julia_libdir))
                    end
                    ENV[$(envvar_name)] = join(filter(!isempty, libpaths), ":")
                """)
            end
        end
        # Close the `check_deps()` function
        println(depsjl_file, "end")
    end
end
function __init__()
    global global_prefix
    # Initialize our global_prefix
    global_prefix = Prefix(joinpath(dirname(@__FILE__), "../", "global_prefix"))
    activate(global_prefix)
    # Find the right download/compression engines for this platform
    probe_platform_engines!()
    # If we're on a julia that's too old, then fixup the color mappings
    if !haskey(Base.text_colors, :default)
        Base.text_colors[:default] = Base.color_normal
    end
end
end # module
