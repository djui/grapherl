%%==============================================================================
%% Copyright 2010 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================

%% @author Adam Lindberg <eproxus@gmail.com>
%% @doc Create graphs of Erlang systems and programs.
%%
%% Valid options are the following:
%% <dl>
%%   <dt>`type'</dt><dd>The type of the file as an atom. This can be
%%     all extensions that graphviz (`dot') supports. Default is `png'.</dd>
%%   <dt>`open'</dt><dd>Command to run on resulting file as a
%%     string. This command will with the output file generated from
%%     `dot' as input.</dd>
%%   <dt>`verbose'</dt><dd>Make `xref' verbose. Default is `false'.</dd>
%%   <dt>`warnings'</dt><dd>Make `xref' print warnings. Default is `false'</dd>
%% </dl>
-module(grapherl).

-copyright("Erlang Solutions Ltd.").
-author("Adam Lindberg <eproxus@gmail.com>").

-export([ main/1
        , applications/2
        , applications/3
        , modules/2
        , modules/3
        , functioncalls/2
        , functioncalls/3
        , functioncalls/4
        ]).

-ifdef(TEST).
-include("grapherl_tests.hrl").
-endif.

%%==============================================================================
%% API Functions
%%==============================================================================

%% @hidden
main(Args) ->
    {ok, {Flags, _Rest} = Options} = getopt:parse(options(), Args),
    case lists:member(help, Flags) of
        true  -> print_options(), quit(0);
        false -> run(Options)
    end.

run({Options, [Dir, Target]}) ->
    case get_mode(Options) of
        {app, RestOpt} -> run(applications, [Dir, Target, RestOpt]);
        {mod, RestOpt} -> run(modules, [Dir, Target, RestOpt]);
        {funcalls, RestOpt} -> run(functioncalls, [Dir, Target, RestOpt])
    end;
run({_Options, _Other}) ->
    print_options(), quit(1).

get_mode(Options) ->
    case proplists:split(Options, [app, mod, funcalls]) of
        {[[app], []], Rest} -> {app, Rest};
        {[[], [mod]], Rest} -> {mod, Rest};
        {[[], [], [funcalls]], Rest} -> {funcalls, Rest}
    end.

options() ->
    [{help, $h, "help", undefined,
      "Display this help text"},
     {app, $a, "applications", undefined,
      "Analyse application dependencies (mutually exclusive)"},
     {mod, $m, "modules", undefined,
      "Analyse module dependencies (mutually exclusive)"},
     {funcalls, $f, "functioncalls", undefined,
      "Analyse function call dependencies (mutually exclusive)"},
     {type, $t, "type", string,
      "Output file type (otherwise deduced from file name)"}].

print_options() ->
    getopt:usage(options(), filename:basename(escript:script_name()),
                 "SOURCE OUTPUT",
                 [{"SOURCE", "The source directory to analyse"},
                  {"OUTPUT", "Target ouput file"}]).

run(Fun, Args) ->
    try apply(?MODULE, Fun, Args) of
        ok             -> quit(0);
        {error, Error} -> quit(2, Error)
    catch
        error:type_not_specified -> quit(2, 'File type not specified')
    end.

%% @equiv applications(Dir, Target, [{type, png}])
applications(Dir, Target) ->
    applications(Dir, Target, [{type, png}]).

%% @doc Generate an application dependency graph based on function calls.
%%
%% `Dir' is the library directory of the release you want to graph. `Target'
%5 is the target filename (without extension).
applications(Dir, Target, Options) ->
    check_for_dot(),
    try
        initialize_xref(?MODULE, Options),
        ok(xref:add_release(?MODULE, Dir, {name, ?MODULE})),
        Excluded = ifc(proplists:is_defined(include_otp, Options),
                       [], otp_apps())
            ++ proplists:get_value(excluded, Options, []),
        Results = ok(xref:q(?MODULE, "AE")),
        Relations = [uses(F, T) ||
                        {F, T} <- Results,
                        F =/= T,
                        not lists:member(F, Excluded),
                        not lists:member(T, Excluded)],
        create(["node [shape = tab];\n"] ++ Relations, Target, Options),
        stop_xref(?MODULE)
    catch
        throw:Error ->
            stop_xref(?MODULE),
            Error
    end.


%% @equiv modules(Dir, Target, [{type, png}])
modules(Dir, Target) ->
    modules(Dir, Target, [{type, png}]).

%% @doc Generate a module dependency graph for an application.
%%
%% `Dir' is the directory of the application. `Target' is the target
%% filename (without extension).
%%
%% All modules in the `ebin' folder in the directory specified in
%% `Dir' will be included in the graph. The option `no_ebin' will, if
%% set to true or just included as an atom, use the `Dir' directory as
%% a direct source for .beam files.
modules(Dir, Target, Options) ->
    %% TODO: Thickness of arrows could be number of calls?
    check_for_dot(),
    try
        initialize_xref(?MODULE, Options),
        Path = get_ebin_path(Dir),
        ok(xref:add_directory(?MODULE, Path)),
        Modules = case ok(xref:q(?MODULE, "AM")) of
                      [] -> throw({error, no_modules_found});
                      Else  -> Else
                  end,
        Query = fmt("ME ||| ~w", [Modules]),
        Results = ok(xref:q(?MODULE, Query)),
        Relations = [uses(F, T) || {F, T} <- Results, F =/= T],
        create(["node [shape = box];\n"]
               ++ [fmt("\"~w\";", [M]) || M <- Modules]
               ++ Relations, Target, Options),
        stop_xref(?MODULE)
    catch
        throw:Error ->
            stop_xref(?MODULE),
            Error
    end.

%% @equiv functioncalls(ModuleFile, [], Target)
functioncalls(ModuleFile, Target) ->
    functioncalls(ModuleFile, [], Target).

%% @equiv functioncalls(ModuleFile, Excludes, Target, [{type,png}])
functioncalls(ModuleFile, Excludes, Target) ->
    functioncalls(ModuleFile, Excludes, Target, [{type,png}]).

%% @doc Generate a function call dependency graph for a Module.
%%
%% `Module' is the target module. `Target' is the target filename
%% (without extension).
%%
%% All function calls from the module `Module' will be in the graph.
%% The option `no_ebin' will, if set to true or just included as an
%% atom, use the `Dir' directory as a direct source for .beam files.
functioncalls(ModuleFile, Excludes, Target, Options) ->
    %% TODO: Thickness of arrows could be number of calls?
    check_for_dot(),
    try
        initialize_xref(?MODULE, Options),
        ok(xref:add_module(?MODULE, ModuleFile)),
        Module = erlang:list_to_atom(filename:basename(ModuleFile, ".beam")),
        Query = fmt("E | ~w", [Module]),
        Results = ok(xref:q(?MODULE, Query)),
        Relations = [uses(F, T, Module) || {F, {TM,_,_}=T} <- Results, F =/= T,
                                           not lists:member(TM, Excludes)],
        create(["node [shape = box];\n"] ++ Relations, Target, Options),
        stop_xref(?MODULE)
    catch
        throw:Error ->
            stop_xref(?MODULE),
            Error
    end.

%%==============================================================================
%% Internal Functions
%%==============================================================================

get_ebin_path(Dir) ->
    case filelib:wildcard(filename:join(Dir, "*.beam")) of
        []     -> filename:join(Dir, "ebin");
        _Beams  -> Dir
    end.

initialize_xref(Name, Options) ->
    case xref:start(Name) of
        {error, {already_started, _}} ->
            stop_xref(Name),
            xref:start(Name);
        {ok, _Ref} ->
            ok
    end,
    XRefOpts = [{verbose, proplists:is_defined(verbose, Options)},
                {warnings, proplists:is_defined(warnings, Options)}],
    ok = xref:set_default(Name, XRefOpts).

stop_xref(Ref) ->
    xref:stop(Ref),
    ok.

get_type(Options, Target) ->
    case proplists:get_value(type, Options) of
        undefined -> type_from_filename(Target);
        Type -> atom_to_list(Type)
    end.

type_from_filename(Filename) ->
    case filename:extension(Filename) of
        ""          -> erlang:error(type_not_specified);
        "." ++ Type -> Type
    end.

file(Lines) ->
    fmt("digraph application_graph {~n~s}~n", [Lines]).

uses({FromM,FromF,FromA}, {ToM,ToF,ToA}, FromM) ->
    fmt("\"~w:~w/~w\" [style=filled, fillcolor=yellow]"
        "\"~w:~w/~w\" -> \"~w:~w/~w\";~n",
        [FromM, FromF, FromA, FromM, FromF, FromA, ToM, ToF, ToA]);
uses({FromM,FromF,FromA}, {ToM,ToF,ToA}, _) ->
    fmt("\"~w:~w/~w\" -> \"~w:~w/~w\";~n",
        [FromM, FromF, FromA, ToM, ToF, ToA]).

uses(From, To) ->
    fmt("  \"~w\" -> \"~w\";~n", [From, To]).

create(Lines, Target, Options) ->
    case dot(file(Lines), Target, get_type(Options, Target)) of
        {"", File} ->
            case proplists:get_value(open, Options) of
                undefined -> ok;
                Command -> os:cmd(Command ++ " " ++ File), ok
            end;
        {Error, _File} ->
            {error, hd(string:tokens(Error, "\n"))}
    end.

check_for_dot() ->
    case os:cmd("dot -V") of
        "dot " ++ _ ->
            ok;
        _Else ->
            erlang:error("dot was not found, please install graphviz",[])
    end.

dot(File, Target, Type) ->
    TmpFile = make_tempfile(),
    ok = file:write_file(TmpFile, File),
    TargetName = add_extension(Target, Type),
    Result = os:cmd(fmt("dot -T~p -o~p ~p", [Type, TargetName, TmpFile])),
    ok = file:delete(TmpFile),
    {Result, TargetName}.

make_tempfile() ->
    string:strip(os:cmd("mktemp -t " ?MODULE_STRING ".XXXX"), right, $\n).

add_extension(Target, Type) ->
    case filename:extension(Target) of
        "." ++ Type -> Target;
        _Else -> Target ++ "." ++ Type
    end.

otp_apps() ->
    Apps = ok(file:list_dir(filename:join(code:root_dir(), "lib"))),
    [list_to_atom(hd(string:tokens(A, "-"))) || A <- Apps].

quit(ExitCode) ->
    erlang:halt(ExitCode).

quit(ExitCode, Msg) ->
    quit(ExitCode, "~p", [Msg]).

quit(ExitCode, Fmt, Data) ->
    io:format(standard_error, "~p: error: "++Fmt++"~n", [?MODULE|Data]),
    timer:sleep(500),
    erlang:halt(ExitCode).

fmt(Fmt, Data) -> lists:flatten(io_lib:format(Fmt, Data)).

ok({ok, Result}) -> Result;
ok(Error)        -> throw(Error).

ifc(true, True, _)   -> True;
ifc(false, _, False) -> False.
