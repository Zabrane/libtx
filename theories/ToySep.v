(** This module contains a minimalistic implementation of separation logic *)
From Coq Require Import
     List
     Omega
     Tactics
     Structures.OrdersEx.

From Containers Require Import
     OrderedType
     OrderedTypeEx
     MapInterface
     MapFacts
     MapAVLInstance.

From QuickChick Require Import
     QuickChick.

Require Import FoldIn.

Import ListNotations.

Reserved Notation "aid '@' req '<~' ret" (at level 30).

Section IOHandler.
  Context {AID : Set} `{AID_ord : OrderedType AID}.

  Inductive HandlerRet {req_t state_t : Type} (req : req_t) (rep_t : req_t -> Set) : Type :=
  | r_return : forall (reply : rep_t req)
                 (state' : state_t)
    , HandlerRet req rep_t
  | r_stall : HandlerRet req rep_t.

  Local Notation "'Nondeterministic' a" := ((a) -> Prop) (at level 200).

  Record t : Type :=
    {
      h_state         : Set;
      h_req           : Set;
      h_ret           : h_req -> Set;
      h_initial_state : Nondeterministic h_state;
      h_eval          : forall (state : h_state)
                          (aid : AID)
                          (req : h_req),
                        Nondeterministic @HandlerRet h_req h_state req h_ret;
    }.
End IOHandler.

Section Trace.
  Variable AID : Set.
  Variable H : @t AID.

  Record TraceElem : Set :=
    trace_elem { te_aid : AID;
                 te_req : H.(h_req);
                 te_ret : H.(h_ret) te_req;
               }.

  Definition Trace := list TraceElem.

  Definition valid_trace_elem (te : TraceElem) (s s' : H.(h_state)) : Prop :=
    match te with
    | trace_elem aid req ret =>
      let hret := r_return req (h_ret H) ret s' in
      h_eval H s aid req hret
    end.

  (** Property that tells if a certain sequence of side effects is
  "physically possible". E.g. mutex can't be taken twice, messages
  don't travel backwards in time, memory doesn't change all by
  itself and so on: *)
  Inductive PossibleTrace (state : H.(h_state)) : Trace -> Prop :=
  | pt_nil : PossibleTrace state []

  | pt_cons : forall (state' : H.(h_state)) (trace_elem : TraceElem) (trace_tail : Trace),
        valid_trace_elem trace_elem state state' ->
        PossibleTrace state' trace_tail ->
        PossibleTrace state (trace_elem :: trace_tail).
End Trace.

Global Arguments TraceElem {_} {_}.
Global Arguments te_aid {_} {_}.
Global Arguments te_req {_} {_}.
Global Arguments te_ret {_} {_}.
Global Arguments trace_elem {_} {_}.
Global Arguments PossibleTrace {_} {_}.
Global Arguments pt_nil {_} {_}.
Global Arguments pt_cons {_} {_}.
Global Arguments valid_trace_elem {_} {_}.

Section Actor.
  Context {AID : Set} `{AID_ord : OrderedType AID} {H : @t AID}.

  CoInductive Actor : Type :=
  | a_cont : forall (pending_req : H.(h_req))
               (continuation : H.(h_ret) pending_req -> option Actor)
           , Actor.

  Definition Actors := Map[AID, Actor].

  Record ModelState : Type :=
    mkState
      {
        m_actors : Actors;
        m_state  : H.(h_state);
      }.

  Definition enter_syscall aid (req : h_req H) cont (ret : HandlerRet req (h_ret H)) ms :=
    match ms with
      {| m_state := s; m_actors := aa |} =>
      match ret with
      | r_stall _ _         => ms
      | r_return _ _ rep s' =>
        let aa' := match cont rep with
                   | Some a' => add aid a' aa
                   | None    => remove aid aa
                   end in
        mkState aa' s'
      end
    end.

  Definition is_reachable (ms ms' : ModelState) (aid : AID) (HIn : In aid (m_actors ms)) : Prop :=
    match ms with
      {| m_state := s |} =>
      match find' aid (m_actors ms) HIn with
      | a_cont req cont =>
        exists ret : @HandlerRet H.(h_req) H.(h_state) req H.(h_ret),
          H.(h_eval) s aid req ret /\
          ms' = enter_syscall aid req cont ret ms
      end
    end.

  (** Constructively define a property that certain model state is
  reachable from a given deterministic program [initial_actors] and
  nondeterministic handler state *)
  Inductive ReachableState {initial_actors : Actors} : ModelState -> Prop :=
  | model_init : forall s0,
      H.(h_initial_state) s0 ->
      ReachableState {| m_actors := initial_actors;
                        m_state  := s0;
                     |}

  | model_step : forall (aid : AID) (ms ms' : ModelState) (HIn : In aid (m_actors ms)),
      is_reachable ms ms' aid HIn ->
      ReachableState ms ->
      ReachableState ms'.

  Definition valid_transition (ms : ModelState) (te : TraceElem) (s' : H.(h_state)) :=
     match te, ms with
     | trace_elem aid req ret, mkState aa s =>
       {HIn : In aid aa |
        let HReq := match find' aid aa HIn with
                    | a_cont req' _ => req = req'
                    end in
        HReq /\ valid_trace_elem te (m_state ms) s'}
     end.

  Definition apply_trace_elem (ms : ModelState) (te : TraceElem) (s' : H.(h_state))
             (Hte : valid_transition ms te s') : ModelState.
    destruct te as [aid req ret].
    destruct ms as [aa s].
    destruct Hte as [HIn [Hreq Hs]].
    destruct (find' aid aa HIn) as [req0 cont].
    refine (enter_syscall aid req0 cont _ (mkState aa s)).
    - rewrite <-Hreq.
      apply (r_return _ _ ret s').
  Defined.

  Lemma apply_trace_elem_reachable : forall {initial_actors} (ms : ModelState) (te : TraceElem) s',
      @ReachableState initial_actors ms ->
      forall Hte : valid_transition ms te s',
        @ReachableState initial_actors (apply_trace_elem ms te s' Hte).
  Proof.
    intros initial_actors ms te s' Hms Hte.
    destruct te as [aid req ret].
    destruct ms as [aa s].
    destruct Hte as [HIn [Hreq Heval]].
    refine (model_step aid (mkState aa s) _ HIn _ Hms).
    simpl.
    destruct (find' aid aa HIn) as [req' cont].
    destruct Hreq.
    exists (r_return _ _ ret s').
    easy.
  Qed.
End Actor.

Section ComposeHandlers.
  Context {AID : Set} `{OrderedType AID}.

  Definition compose_state (h1 h2 : @t AID) : Set :=
    h_state h1 * h_state h2.

  Definition compose_req (h1 h2 : @t AID) : Set :=
    h_req h1 + h_req h2.

  Hint Transparent compose_state.

  Definition compose_initial_state (h1 h2 : @t AID) state :=
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

Global Arguments h_state {_} {_}.
Global Arguments h_req {_}.
Global Arguments h_ret {_}.
Global Arguments h_initial_state {_}.
Global Arguments h_eval {_}.
Global Arguments Actor {_} {_}.
Global Arguments a_cont {_} {_}.
Global Arguments ModelState {_} {_}.
Global Arguments m_actors {_} {_} {_}.
Global Arguments m_state {_} {_} {_}.
Global Arguments ReachableState {_} {_}.
Global Arguments model_init {_} {_} {_} {_}.
Global Arguments PossibleTrace {_} {_}.

Module Mutable.
  Inductive req_t {T : Set} :=
  | get : req_t
  | put : T -> req_t.

  Section defs.
  Context (AID T : Set) `{AID_ord : OrderedType AID} (initial_state : T -> Prop).

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

  Definition t : t :=
    {|
      h_state := T;
      h_req := req_t;
      h_initial_state := initial_state;
      h_eval := fun s0 aid req ret => ret = eval_f s0 aid req;
    |}.
  End defs.
End Mutable.

Module Mutex.
  Inductive req_t : Set :=
  | grab    : req_t
  | release : req_t.

  Local Definition ret_t (_ : req_t) : Set := True.

  Section defs.
  Variable AID : Set.

  Local Definition state_t : Set := option AID.

  Local Definition eval_f (s0 : state_t) (aid : AID) (req : req_t) : @HandlerRet req_t state_t req ret_t :=
    match req, s0 with
    | grab, None   => r_return _ _ I (Some aid)
    | grab, Some _ => r_stall _ _
    | release, _   => r_return _ _ I None
    end.

  Definition t : t :=
    {|
      h_state         := state_t;
      h_req           := req_t;
      h_initial_state := fun s0 => s0 = None;
      h_eval          := fun s0 aid req ret => ret = eval_f s0 aid req;
    |}.

  Local Notation "aid '@' req '<~' ret" := (@trace_elem AID t aid req ret).

  Theorem no_double_grab : forall (s : state_t) (a1 a2 : AID),
      ~(@PossibleTrace AID t s
                      [ a1 @ grab <~ I;
                        a2 @ grab <~ I
                      ]).
  Proof.
    intros s a1 a2 H.
    inversion H as [|s' te tt Hvalid Ht]. subst.
    inversion Ht as [|s'' te' tt' Hvalid' Ht']. subst.
    simpl in *.
    destruct s; simpl in *; inversion Hvalid; subst.
    - easy.
  Qed.
  End defs.
End Mutex.

Module ExampleModelDefn.
  Definition AID : Set := nat.

  Local Definition handler := compose (Mutable.t AID nat (fun a => a = 0))
                                      (Mutex.t AID).

  Notation "'do' V '<-' I ; C" := (@a_cont AID handler (I) (fun V => Some C))
                                    (at level 100, C at next level, V ident, right associativity).

  Notation "'done' I" := (@a_cont AID handler (I) (fun _ => None))
                           (at level 100, right associativity).

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
    do _ <- put 0;
    infinite_loop aid.

  (* Data race example: *)
  Local Definition counter_race (_ : AID) : Actor :=
    do v <- get;
    done put (v + 1).

  (* Fixed example: *)
  Local Definition counter_correct (_ : AID) : Actor :=
    do _ <- grab;
    do v <- get;
    do _ <- put (v + 1);
    done release.

  Local Definition two_actors := add 0 (counter_race 0) (add 1 (counter_race 1) (empty _) : Map [nat, Actor]).
End ExampleModelDefn.
