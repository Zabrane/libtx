(** This module contains a minimalistic implementation of separation logic *)
From Coq Require Import
     List
     Omega
     Structures.OrdersEx.

From Containers Require Import
     OrderedType
     OrderedTypeEx
     MapInterface
     MapFacts
     MapAVLInstance.

From QuickChick Require Import
     QuickChick.

Import ListNotations.

Reserved Notation "aid '@' req '<~' ret" (at level 30).

Section IOHandler.
  Variable AID : Set.
  Context {AID_ord : OrderedType AID}.

  Inductive HandlerRet {req_t state_t : Type} (req : req_t) (rep_t : req_t -> Set) : Type :=
  | r_return : forall (reply : rep_t req)
                 (state' : state_t)
    , HandlerRet req rep_t
  | r_stall : HandlerRet req rep_t.

  Notation "'Nondeterministic' a" := ((a) -> Prop) (at level 200).

  Record t : Type :=
    {
      h_state         : Type;
      h_req           : Set;
      h_ret           : h_req -> Set;
      h_initial_state : Nondeterministic h_state;
      h_eval          : forall (state : h_state)
                          (aid : AID)
                          (req : h_req),
                        Nondeterministic @HandlerRet h_req h_state req h_ret;
    }.

  CoInductive Actor {T : t} : Type :=
  | a_sync : forall (pending_req : T.(h_req))
               (continuation : T.(h_ret) pending_req -> Actor)
             , Actor
  | a_dead : Actor.

  Definition Actors {H : t} := Map[AID, (@Actor H)].

  Inductive TraceElem {H : t} :=
  | trace_elem : forall (aid : AID) (req : H.(h_req)) (ret : H.(h_ret) req), TraceElem.

  Definition Trace {H : t} := list (@TraceElem H).

  Record ModelState {H : t} : Type :=
    mkState
      {
        m_actors : @Actors H;
        m_state  : H.(h_state);
        m_trace  : @Trace H;
      }.

  Definition enter_syscall {H} aid (req : h_req H) cont (ret : HandlerRet req (h_ret H)) ms :=
    match ms with
      {| m_state := s; m_actors := aa; m_trace := t |} =>
      match ret with
      | r_stall _ _         => ms
      | r_return _ _ rep s' =>
        let a' := cont rep in
        let aa' := add aid a' aa in
        mkState H aa' s' (trace_elem aid req rep :: t)
      end
    end.

  (* TODO: Reap zombie actors *)
  Definition eval_sync {H : t} (aid : AID) (ms : ModelState) (ms' : ModelState) : Prop :=
    match ms with
      {| m_state := s; m_actors := aa; m_trace := t |} =>
      match find aid aa with
      | None =>
        ms = ms'
      | Some a_dead =>
        ms = ms'
      | Some (a_sync req cont) =>
        forall ret : @HandlerRet H.(h_req) H.(h_state) req H.(h_ret),
          H.(h_eval) s aid req ret ->
          ms' = enter_syscall aid req cont ret ms
      end
    end.

  (* Ltac forward1 ms aid ret := *)

  (** Constructively define a property that certain model state is
  reachable from a given deterministic program [initial_actors] and
  nondeterministic handler state *)
  Inductive ReachableState {H : t} {initial_actors : Actors} : ModelState -> Prop :=
  | model_init : forall s0,
      H.(h_initial_state) s0 ->
      ReachableState {| m_actors := initial_actors;
                        m_state  := s0;
                        m_trace  := nil;
                     |}

  | model_step : forall (aid : AID) (ms : ModelState),
      forall ms', eval_sync aid ms ms' ->
             ReachableState ms ->
             ReachableState ms'.

  Definition exit {T : t} : @Actor T := a_dead.

  Section ComposeHandlers.
    Definition compose_state h1 h2 : Type :=
      h_state h1 * h_state h2.

    Definition compose_req h1 h2 : Set :=
      h_req h1 + h_req h2.

    Hint Transparent compose_state.

    Definition compose_initial_state h1 h2 state :=
      h1.(h_initial_state) (fst state) /\ h2.(h_initial_state) (snd state).

    Hint Transparent compose_initial_state.

    Definition compose_ret_t (h1 h2 : t) (req : compose_req h1 h2) : Set :=
      match req with
      | inl l => h1.(h_ret) l
      | inr r => h2.(h_ret) r
      end.

    Hint Transparent compose_ret_t.

    Definition ComposeHandlerRet h1 h2 req : Type :=
      @HandlerRet (compose_req h1 h2)
                  (compose_state h1 h2)
                  req
                  (compose_ret_t h1 h2).

    Definition compose_eval h1 h2
               (state : compose_state h1 h2)
               (aid : AID)
               req
               (ret : ComposeHandlerRet h1 h2 req) : Prop.
      refine (
          (let (s1, s2) := state in
           match req as req' return (req = req' -> Prop) with
           | inl req' => fun H => h1.(h_eval) s1 aid req' _
           | inr req' => fun H => h2.(h_eval) s2 aid req' _
           end) (eq_refl req));
        subst;
        destruct ret;
        try simpl in reply;
        constructor; assumption.
    Defined.

    Definition compose (h1 h2 : t) : t :=
      {| h_state         := compose_state h1 h2;
         h_req           := compose_req h1 h2;
         h_ret           := compose_ret_t h1 h2;
         h_initial_state := compose_initial_state h1 h2;
         h_eval          := compose_eval h1 h2;
      |}.
  End ComposeHandlers.
End IOHandler.

Notation "aid '@' req '<~' ret" := (trace_elem aid req ret).

Arguments compose {_}.
Arguments h_state {_}.
Arguments h_req {_}.
Arguments h_ret {_}.
Arguments h_initial_state {_}.
Arguments h_eval {_}.
Arguments Actor {_} {_}.
Arguments a_sync {_} {_}.
Arguments a_dead {_} {_}.
Arguments exit {_} {_}.
Arguments ModelState {_} {_}.
Arguments m_actors {_} {_} {_}.
Arguments m_state {_} {_} {_}.
Arguments m_trace {_} {_} {_}.
Arguments ReachableState {_} {_}.
Arguments model_init {_} {_} {_} {_}.
Arguments model_step {_} {_} {_} {_}.

Module Mutable.
  Inductive req_t {T : Set} :=
  | get : req_t
  | put : T -> req_t.

  Section defs.
  Variables (AID T : Set) (initial_state : T -> Prop).

  Local Definition ret_t (req : @req_t T) : Set :=
    match req with
    | get => T
    | _   => True
    end.

  Local Definition eval_f (s0 : T) (aid : AID) (req : req_t) : @HandlerRet req_t T req ret_t :=
    match req with
    | get   => r_return _ _ s0 s0
    | put x => r_return _ _ I x
    end.

  Definition t : (t AID) :=
    {|
      h_state := T;
      h_req := req_t;
      h_initial_state := initial_state;
      h_eval := fun s0 aid req ret => ret = eval_f s0 aid req;
    |}.
  End defs.
End Mutable.

Module Mutex.
  Inductive req_t :=
  | grab    : req_t
  | release : req_t.

  Local Definition ret_t (_ : req_t) : Set := True.

  Section defs.
  Variable AID : Set.

  Local Definition state_t : Type := option AID.

  Local Definition eval_f (s0 : state_t) (aid : AID) (req : req_t) : @HandlerRet req_t state_t req ret_t :=
    match req, s0 with
    | grab, None   => r_return _ _ I (Some aid)
    | grab, Some _ => r_stall _ _
    | release, _   => r_return _ _ I None
    end.

  Definition t : (t AID) :=
    {|
      h_state := state_t;
      h_req := req_t;
      h_initial_state := fun s0 => s0 = None;
      h_eval := fun s0 aid req ret => ret = eval_f s0 aid req;
    |}.
  End defs.
End Mutex.

Module ExampleModelDefn.
  Definition AID : Set := nat.

  Local Definition handler := compose (Mutable.t AID nat (fun a => a = 0)) (Mutex.t AID).

  Notation "'do' V '<-' I ; C" := (@a_sync AID handler (I) (fun V => C))
                                  (at level 100, C at next level, V ident, right associativity).

  Local Definition put (val : nat) : handler.(h_req) :=
    inl (Mutable.put val).

  Local Definition get : h_req handler :=
    inl (Mutable.get).

  Local Definition grab : h_req handler :=
    inr (Mutex.grab).

  Local Definition release : h_req handler :=
    inr (Mutex.release).

  (* Just a demonstration how to define a programs that loops
  indefinitely, as long as it does IO: *)
  Local CoFixpoint infinite_loop (aid : AID) : Actor :=
    a_sync (put 0) (fun ret => infinite_loop aid).

  (* Data race example: *)
  Local Definition counter_race (_ : AID) : Actor :=
    do v <- get;
    do _ <- put (v + 1);
    exit.

  (* Fixed example: *)
  Local Definition counter_correct (_ : AID) : Actor :=
    do _ <- grab;
    do v <- get;
    do _ <- put (v + 1);
    do _ <- release; exit.

  Local Definition two_actors := add 0 (counter_race 0) (add 1 (counter_race 1) (empty _) : Map [nat, Actor]).

  Example race1 :
    exists (s : ModelState handler),
      ReachableState handler two_actors s ->
      find 0 (m_actors s) = Some a_dead /\ find 1 (m_actors s) = Some a_dead ->
      fst (m_state s) = 1.
  Proof.
    set (ms0 := {| m_actors := two_actors;
                   m_state  := (0, None);
                   m_trace  := [];
                |}).
    forward ms0
            [0 @ get <~ 0;
             1 @ get <~ 0;
             0 @ put 1 <~ True;
             1 @ put 1 <~ True
            ].


               1:
       (1, get, 0),
      ]

    intros s Hrs [Hf1 Hf2].
    inversion H as [s0 Hs0|aid ms].
    - destruct Hs0.


End ExampleModelDefn.
