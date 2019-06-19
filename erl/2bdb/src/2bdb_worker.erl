-module('2bdb_worker').

-behaviour(gen_statem).

-include_lib("stdlib/include/assert.hrl").

%% API
-export([start_link/0]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3, code_change/4]).
-export([handle_event/4]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% Types
%%%===================================================================

%%--------------------------------------------------------------------
%% Replication protocol:
%%--------------------------------------------------------------------

-type txid() :: reference().

-type key_hash() :: binary().

-type seqno() :: non_neg_integer().

-type read_ops() :: [{key_hash(), seqno()}].

-type write_ops() :: [{_Key, seqno(), value()}].

-type offset() :: non_neg_integer().

-record(tx,
        { id               :: txid()
        , estimated_offset :: offset()
        , partitions       :: [integer()] %% Partitions (excluding the current one)
                                          %% containing other parts of the transaction
        , reads            :: read_ops()
        , writes           :: write_ops()
        }).

-type tx() :: #tx{}.

-type meta_op() :: {set_repl_params,
                    #{ window_size     := non_neg_integer()
                     , lock_expiration := non_neg_integer()
                     }}.

-type lock_op() :: {grab_locks, txid(), [key_hash()]}
                 | {keep_locks, txid()}
                 .

-type tlog_op() :: meta_op()
                 | tx()
                 | lock_op()
                 .

%%--------------------------------------------------------------------
%% Internal types:
%%--------------------------------------------------------------------

-type state() :: incomplete_window
               | behind              %% TODO not implemented
               | hold_on             %% TODO not implemented
               | in_sync
               .

-type os_timestamp() :: integer().

-record(try_write_trans,
        { txid     :: txid()
        , ts_begin :: os_timestamp() %% For performance measurements only
        , reads    :: [key_hash()]
        , writes   :: [{_Key, _Value}]
        }).

-record(data,
        { storage = ets_wrapper :: module()
        , window_size     = 1   :: non_neg_integer()
        , lock_expiration = 0   :: non_neg_integer()
        , num_replayed    = 0   :: non_neg_integer()
        , offset          = 0   :: offset()
        , seqno_tab             :: ets:tid()
        , callback_tab          :: ets:tid()
        , producer_data         :: producer()
        , consumer_data         :: consumer()
        }).

-record(seqno_cache,
        { key              :: key_hash()
        , seqno            :: seqno()
        , last_seen_offset :: offset()
        }).

-record(callback_ref,
        { txid             :: txid()
        , reply_to         :: gen_statem:from()
        , estimated_offset :: offset() %% This offset should not be very precise,
                                       %% it's used only for hangup detection
        , ts_begin         :: os_timestamp()
        }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_statem process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, Pid :: pid()}.
start_link() ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).


-spec try_write_trans(boolean(), #try_write_trans{}) -> ok | retry.
try_write_trans(GrabLock, Tx) ->
    gen_statem:call(?SERVER, {try_write_trans, Tx}).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() -> handle_event_function.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) ->
                  gen_statem:init_result(term()).
init([]) ->
    process_flag(trap_exit, true),
    SeqNoTab    = ets:new( '2bdb_seqno_tab'
                         , [ {keypos, #seqno_cache.key}
                           , protected
                           , named_table
                           ]
                         ),
    CallbackTab = ets:new( '2bdb_callback_tab'
                         , [{keypos, #callback_ref.txid}]
                         ),
    InitialData = #data{ seqno_tab    = SeqNoTab
                       , callback_tab = CallbackTab
                       },
    %% TODO: read persisted data
    Data = InitialData,
    {ok, incomplete_window, Data}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for every event a gen_statem receives.
%% @end
%%--------------------------------------------------------------------
%% Handle import transaction:
handle_event({call, From}, {import_trans, TrueOffset, Tx}, OldState, Data0) ->
    Data = handle_import_trans(Data0, TrueOffset, Tx),
    #data{ num_replayed = NumImported
         , window_size  = WindowSize
         } = Data,
    NextState = if NumImported >= WindowSize,
                   OldState =:= incomplete_window ->
                        in_sync;
                   true ->
                        OldState
                end,
    {next_state, NextState, Data, [{reply, From, ok}]};
%% Handle local transactions:
handle_event({call, From}, Tx = #try_write_trans{}, in_sync, Data) ->
    %% We are ready to write transactions:
    do_write_trans(Data, From, Tx);
handle_event({call, _}, #try_write_trans{}, hold_on, _Data) ->
    %% We need to back off. Queue up this transaction for now
    {keep_state_and_data, [postpone]};
handle_event({call, From}, #try_write_trans{}, _State, _Data) ->
    %% TODO: not the best solution... Will cause busy loop
    %% 1) Forward tx to a different host
    %%
    %% 2) or postpone the transaction and check the offset: if offset
    %% difference is too large, drop the tx
    {keep_state_and_data, [{reply, From, retry}]};
%% Common actions:
handle_event({call, From}, EvtData, State, _Data) ->
    ?slog(#{ what => "Unknown call"
           , data => EvtData
           , current_state => State
           }),
    Reply = {error, unknown_call},
    {keep_state_and_data, [{reply, From, Reply}]};
handle_event(Event, EvtData, State, _Data) ->
    ?slog(#{ what => "Unknown event"
           , type => Event
           , data => EvtData
           , current_state => State
           }),
    keep_state_and_data.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_statem when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_statem terminates with
%% Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(_Reason, _State, _Data) -> any().
terminate(_Reason, _State, _Data) ->
    void.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(
        OldVsn :: term() | {down,term()},
        State :: term(), Data :: term(), Extra :: term()) ->
                         {ok, NewState :: term(), NewData :: term()} |
                         (Reason :: term()).
code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec do_write_trans( #data{}
                    , gen_statem:from()
                    , #try_write_trans{}
                    ) -> keep_state_and_data.
do_write_trans(Data, From, Tx) ->
    #data{ seqno_tab    = SeqNoTab
         , callback_tab = CallbackTab
         , offset       = Offset
         } = Data
    #try_write_trans{ txid     = Txid
                    , ts_begin = TsBegin
                    , reads    = Reads
                    , writes   = Writes
                    } = Tx,
    ReadOps = [{KeyHash, get_seqno(Data, KeyHash)} || KeyHash <- Reads],
    WriteOps = [{Key, get_seqno(Data, key_hash(Key)), Val}
                || {Key, Val} <- Writes],
    %% Produce transaction to the tlog (asynchronously, because we are
    %% very optimistic!):
    produce(#tx{ id         = Txid
               , partitions = []   %% TODO: Chop it up
               , reads      = ReadOps
               , write      = WriteOps
               }),
    %% Write transaction reference to the callback buffer:
    ets:insert( CallbackTab
              , #callback_ref{ txid             = Txid
                             , reply_to         = From
                             , estimated_offset = Offset
                             , ts_begin         = TsBegin
                             }
              ),
    %% Don't reply yet:
    keep_state_and_data.

-spec handle_import_trans(#data{}, offset(), #tx{}) -> #data{}.
handle_import_trans(Data0, TrueOffset, Tx) ->
    #data{ window_size  = WindowSize
         , num_replayed = NumReplayed
         } = Data0,
    #tx{ id               = TxId
       , estimated_offset = EstimatedOffset
       , writes           = WriteOps
       , reads            = ReadOps
       } = Tx,
    ?assert(EstimatedOffset =< TrueOffset),
    WriteSeqNos = [{key_hash(Key), SeqNo}
                   || {Key, SeqNo, _} <- WriteOps],
    Valid = (TrueOffset - EstimatedOffset < WindowSize) andalso
            validate_locks(Data0, WriteOps) andalso
            validate_seqnos(Data0, WriteSeqNos) andalso
            validate_seqnos(Data0, ReadOps),
    Data = Data0#data{ offset       = TrueOffset
                     , num_replayed = NumReplayed + 1
                     },
    if Valid ->
            do_import_transaction(WriteOps),
            maybe_complete_transaction(Data, ok);
       true ->
            maybe_complete_transaction(Data, retry)
    end,
    Data.

-spec get_seqno(#data{}, key_hash()) -> seqno().
get_seqno(Data, KeyHash) ->
    #data{ seqno_tab   = Tab
         , window_size = WindowSize
         , offset      = Offset
         } = Data,
    case ets:lookup(Tab, KeyHash) of
        [#seqno_cache{seqno = N, last_seen_offset = LSO}]
          when Offset - LSO < WindowSize ->
            LSO;
        _ ->
            0
    end.

-spec do_import_transaction(#data{}, write_ops()) -> ok.
do_import_transaction(Data, WriteOps) ->
    Storage:put([{Key, Val} || {Key, _, Val} <- WriteOps]),
    bump_seqnos(Data, WriteOps).

-spec bump_seqnos(#data{}, write_ops()) -> ok.
bump_seqnos(Data, WriteOps) ->
    #data{ seqno_tab = SeqNoTab
         , offset    = Offset
         , storage   = Storage
         } = Data,
    Inserts = [#seqno_cache{ key              = key_hash(Key)
                           , seqno            = OldSeqNo + 1
                           , last_seen_offset = Offset
                           }
               || {Key, OldSeqNo, _} <- WriteOps],
    ets:insert(SeqNoTab, Inserts),
    ok.

-spec validate_locks(#data{}, write_ops()) -> boolean().
validate_locks(Data, WriteOps) ->
    %% TODO: Not implemented
    true.

-spec validate_seqnos(#data{}, [{key_hash(), seqno()}]) -> boolean().
validate_seqnos(Data, SeqNos) ->
    try
        [case get_seqno(Data, KeyHash) of
             ExpectedSeqNo -> ok;
             TrueSeqNo     -> throw(mismatch)
         end
         || {KH, ExpectedSeqNo} <- SeqNos],
        true
    catch
        mismatch -> false
    end.

%% Signal `Result' to the transaction process
-spec maybe_complete_transaction(#data{}, txid(), _Result) -> ok.
maybe_complete_transaction(Data, TxId, Result) ->
    #data{callback_tab = Tab} = Data,
    case ets:take(Tab, TxId) of
        [#callback_ref{reply_to = From}] ->
            gen_statem:reply(From, Result);
        [] ->
            %% This transaction didn't originate from our server,
            %% ignore it.
            ok
    end.

-spec produce(#data{}, #tx{}) -> ok.
produce(#data{producer_data = ProducerData}, Tx) ->
    %% TODO: Not implemented
    ok.
