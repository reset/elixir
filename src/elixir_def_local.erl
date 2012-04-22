%% Module responsible for local invocation of macros and functions.
-module(elixir_def_local).
-export([
  build_table/1,
  delete_table/1,
  record/4,
  macro_for/2,
  function_for/3,
  format_error/1,
  check_unused_local_macros/3,
  check_macros_at_runtime/4
]).
-include("elixir.hrl").

%% Table

table(Module) -> ?ELIXIR_ATOM_CONCAT([l, Module]).

build_table(Module) ->
  ets:new(table(Module), [duplicate_bag, named_table, private]).

delete_table(Module) ->
  ets:delete(table(Module)).

record(_Line, _Tuple, _IsMacro, #elixir_scope{module=[]}) -> [];

record(Line, Tuple, IsMacro, #elixir_scope{module=Module}) ->
  ets:insert(table(Module), { Tuple, Line, IsMacro }).

%% Reading

macro_for(_Tuple, #elixir_scope{module=[]}) -> false;

macro_for(Tuple, #elixir_scope{module=Module}) ->
  case ets:lookup(elixir_def:table(Module), Tuple) of
    [{Tuple, Line, Kind, _, Clauses}] when Kind == defmacro; Kind == defmacrop ->
      RewrittenClauses = [rewrite_clause(Clause, Module) || Clause <- Clauses],
      Fun = { 'fun', Line, {clauses, lists:reverse(RewrittenClauses)} },
      { value, Result, _Binding } = erl_eval:exprs([Fun], []),
      Result;
    _ -> false
  end.

function_for(Module, Name, Arity) ->
  Tuple = { Name, Arity },
  case ets:lookup(elixir_def:table(Module), Tuple) of
    [{Tuple, Line, _, _, Clauses}] ->
      RewrittenClauses = [rewrite_clause(Clause, Module) || Clause <- Clauses],
      Fun = { 'fun', Line, {clauses, lists:reverse(RewrittenClauses)} },
      { value, Result, _Binding } = erl_eval:exprs([Fun], []),
      Result;
    _ ->
      [_|T] = erlang:get_stacktrace(),
      erlang:raise(error, undef, [{Module,Name,Arity,[]}|T])
  end.

%% Helpers
%% TODO: Consider caching functions in a table for performance.

rewrite_clause({ call, Line, { atom, Line, _ } = Atom, Args }, Module) ->
  Remote = { remote, Line,
    { atom, Line, ?MODULE },
    { atom, Line, function_for }
  },
  Arity   = { integer, Line, length(Args) },
  FunCall = { call, Line, Remote, [{ atom, Line, Module }, Atom, Arity] },
  { call, Line, FunCall, Args };

rewrite_clause(Tuple, Module) when is_tuple(Tuple) ->
  list_to_tuple(rewrite_clause(tuple_to_list(Tuple), Module));

rewrite_clause(List, Module) when is_list(List) ->
  [rewrite_clause(Item, Module) || Item <- List];

rewrite_clause(Else, _) -> Else.

%% Error handling

check_unused_local_macros(Filename, Module, PMacros) ->
  Table = table(Module),
  [elixir_errors:handle_file_warning(Filename,
    { Line, ?MODULE, { unused_macro, Fun } }) || { Fun, Line } <- PMacros, not ets:member(Table, Fun)].

check_macros_at_runtime(Filename, Module, Macros, PMacros) ->
  Table = table(Module),
  [elixir_errors:form_error(Line, Filename, ?MODULE, { runtime_macro, Fun }) ||
    Fun <- Macros, [Line] <- ets:match(Table, { Fun, '$1', false })],
  [elixir_errors:form_error(Line, Filename, ?MODULE, { runtime_macro, Fun }) ||
    { Fun, _ } <- PMacros, [Line] <- ets:match(Table, { Fun, '$1', false })].

format_error({unused_macro,{Name, Arity}}) ->
  io_lib:format("macro ~s/~B is unused", [Name, Arity]);

format_error({runtime_macro,{Name, Arity}}) ->
  io_lib:format("macro ~s/~B is being invoked before it is defined", [Name, Arity]).