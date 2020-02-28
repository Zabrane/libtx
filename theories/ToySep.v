(*** Minimalistic implementation of concurrent separation logic *)
(** This module defines the model of distributed system used in the
rest of the project. Whether you trust the LibTx depends on whether
you trust the below definitions.

* Motivation

Before diving into lengthy description of the model, let me first
motivate a sceptical reader:

** Q: Why not TLA+?

A: ToySep allows to describe nondeterministic parts of the model in a
way very similar to TLA+. But its deterministic part enjoys from using
a full-fledged functional language

- I want to write inductive proofs

- I want to use a more or less traditional functional language

- I want to extract verified programs

- While TLA+ model checker is top notch, its proof checker isn't, by
  far

** Q: Why not %model checker%?

A: Model checkers show why the code _fails_, which is good for
verifying algorithms, but formal proofs show why the code _works_ (via
tree of assumptions), which is good for reasoning about algorithms
and, in particular, predicting the outcome of optimisations. Also
model checkers can't explore the entire state space of a typical
real-life system with unbounded number of actors.

** Q: Why not Verdi?

- Verdi models are low level: think UDP packets and disk IO. ToySep is
  meant to model systems on a much higher level: think Kafka client
  API.

- Nondeterminisic part of Verdi is hardcoded, while ToySep allows user
  to define custom nondeterministic IO handlers.

** Q: Why not disel?

A: disel models are closer to what I need, but implementation itself
is an incomprehensible, undocumetned burp of ssreflect. Proofs are as
useful as their premises: "garbage in - garbage out". Good model
should be well documented and well understood.

** Q: Why not iris/aneris?

A: iris allows user to define semantics of their very own programming
language. ToySep is focused on proving properties of _regular pure
functinal programs_ that do IO from time to time. Hence it defines
actors in regular Gallina language, rather than some DSL, and frees
the user from reinventing basic control flow constructions.

*)
From Coq Require Import
     List
     Omega
     Tactics
     Sets.Ensembles
     Structures.OrdersEx
     Logic.FunctionalExtensionality.

Import ListNotations.

From Containers Require Import
     OrderedType
     OrderedTypeEx.

From QuickChick Require Import
     QuickChick.

From LibTx Require Import
     InterleaveLists
     FoldIn.

Reserved Notation "aid '@' req '<~' ret" (at level 30).
Reserved Notation "'{{' a '}}' t '{{' b '}}'" (at level 40).
Reserved Notation "'{{' a '&' b '}}' t '{{' c '&' d '}}'" (at level 10).

Global Arguments In {_}.
Global Arguments Complement {_}.
Global Arguments Disjoint {_}.

Ltac inversion_ a := inversion a; subst; auto.

Section IOHandler.
  Context {AID : Set} `{AID_ord : OrderedType AID}.

  Local Notation "'Nondeterministic' a" := ((a) -> Prop) (at level 200).

  Record TraceElem_ {Req : Set} {Ret : Req -> Set} : Set :=
    trace_elem { te_aid : AID;
                 te_req : Req;
                 te_ret : Ret te_req;
               }.

  Record t : Type :=
    {
      h_state         : Set;
      h_req           : Set;
      h_ret           : h_req -> Set;
      h_initial_state : Nondeterministic h_state;
      h_chain_rule    : h_state -> h_state -> @TraceElem_ h_req h_ret -> Prop
    }.

  Definition TraceElem {h : t} : Set := @TraceElem_ h.(h_req) h.(h_ret).

  Definition Trace {h : t} := list (@TraceElem h).
End IOHandler.

Section Hoare.
  Context {AID : Set} {H : @t AID}.

  Section defn.
    Let TE := @TraceElem AID H.
    Let T := @Trace AID H.

    Context {S : Type} {chain_rule : S -> S -> TE -> Prop}.

    Inductive LongStep : S -> T -> S -> Prop :=
    | ls_nil : forall s,
        LongStep s [] s
    | ls_cons : forall s s' s'' te trace,
        chain_rule s s' te ->
        LongStep s' trace  s'' ->
        LongStep s (te :: trace) s''.

    Inductive ValidTrace (trace : T) :=
    | valid_trace : forall s s',
        LongStep s trace s' ->
        ValidTrace trace.

    Definition HoareTriple (pre : S -> Prop) (trace : T) (post : S -> Prop) :=
      forall s s',
        LongStep s trace s' ->
        pre s -> post s'.

    Notation "'{{' a '}}' t '{{' b '}}'" := (HoareTriple a t b).

    Lemma hoare_nil : forall p, {{p}} [] {{p}}.
    Proof.
      intros p s s' Hs.
      inversion_clear Hs. auto.
    Qed.

    Theorem ls_split : forall s s'' t1 t2,
        LongStep s (t1 ++ t2) s'' ->
        exists s', LongStep s t1 s' /\ LongStep s' t2 s''.
    Proof.
      intros.
      generalize dependent s.
      induction t1; intros.
      - exists s.
        split; auto. constructor.
      - inversion_clear H0.
        specialize (IHt1 s' H2).
        destruct IHt1.
        exists x.
        split.
        + apply ls_cons with (s' := s'); firstorder.
        + firstorder.
    Qed.

    Theorem hoare_concat : forall pre mid post t1 t2,
        HoareTriple pre t1 mid ->
        HoareTriple mid t2 post ->
        HoareTriple pre (t1 ++ t2) post.
    Proof.
      intros.
      intros s s' Hs Hpre.
      apply ls_split in Hs. destruct Hs.
      firstorder.
    Qed.

    Lemma hoare_cons : forall (pre mid post : S -> Prop) (te : TE) (trace : T),
        {{pre}} [te] {{mid}} ->
        {{mid}} trace {{post}} ->
        {{pre}} (te :: trace) {{post}}.
    Proof.
      intros.
      specialize (hoare_concat pre mid post [te] trace).
      auto.
    Qed.

    Notation "'{{' A '&' B '}}' t '{{' C '&' D '}}'" :=
        ({{ fun s => A s /\ B s }} t {{ fun s => C s /\ D s }}).

    Lemma hoare_and : forall (A B C D : S -> Prop) (t : T),
        {{ A }} t {{ B }} ->
        {{ C }} t {{ D }} ->
        {{ fun s => A s /\ C s }} t {{ fun s => B s /\ D s }}.
    Abort.

    Definition trace_elems_commute (te1 te2 : TE) :=
      forall s s',
        LongStep s [te1; te2] s' <-> LongStep s [te2; te1] s'.

    Lemma trace_elems_commute_ht : forall pre post te1 te2,
        trace_elems_commute te1 te2 ->
        {{pre}} [te1; te2] {{post}} <-> {{pre}} [te2; te1] {{post}}.
    Proof.
      unfold trace_elems_commute.
      split; intros;
      intros s s' Hss' Hpre;
      specialize (H0 s s');
      apply H0 in Hss';
      apply H1 in Hss';
      apply Hss' in Hpre;
      assumption.
    Qed.

    Lemma trace_elems_commute_symm : forall te1 te2,
        trace_elems_commute te1 te2 ->
        trace_elems_commute te2 te1.
    Admitted.

    Hint Resolve trace_elems_commute_symm.

    Lemma trace_elem_comm_head : forall pre post te1 te2 tail,
        trace_elems_commute te1 te2 ->
        {{pre}} te1 :: te2 :: tail {{post}} ->
        {{pre}} te2 :: te1 :: tail {{post}}.
    Admitted.

    Hint Resolve trace_elem_comm_head.

    Section ExpandTrace.
      Variable te_subset : Ensemble TE.

      Definition Local (prop : S -> Prop) :=
        forall te,
          ~In te_subset te ->
          {{prop}} [te] {{prop}}.

      Definition ChainRuleLocality :=
        forall te te',
          In te_subset te ->
          ~In te_subset te' ->
          trace_elems_commute te te'.

      Example True_is_local : Local (fun s => True).
      Proof. easy. Qed.

      Inductive ExpandedTrace : T -> T -> Prop :=
      | et_nil :
          ExpandedTrace [] []
      | et_match :
          forall te t t',
            Ensembles.In te_subset te ->
            ExpandedTrace t t' ->
            ExpandedTrace (te :: t) (te :: t')
      | et_expand :
          forall te t t',
            ~Ensembles.In te_subset te ->
            ExpandedTrace t t' ->
            ExpandedTrace t (te :: t').

      Hint Transparent Ensembles.In Ensembles.Complement.

      Lemma expand_trace_nil : forall pre post trace,
          Local pre ->
          {{pre}} [] {{post}} ->
          ExpandedTrace [] trace ->
          {{pre}} trace {{post}}.
      Proof.
        intros pre post trace Hl_pre Hp Hexp s s' Hss' Hpre.
        generalize dependent s.
        remember [] as t.
        induction Hexp; intros s Hs' Hs; inversion_ Hs'.
        - specialize (Hp s' s'). auto.
        - exfalso.
          inversion Heqt.
        - apply IHHexp with (s := s'0); auto.
          assert (Hss'0 : LongStep s [te] s'0).
          { apply ls_cons with (s' := s'0). auto. constructor. }
          firstorder.
      Qed.

      Theorem expand_trace_elem : forall pre post te e_trace,
          Local pre ->
          Local post ->
          ExpandedTrace [te] e_trace ->
          {{pre}} [te] {{post}} ->
          {{pre}} e_trace {{post}}.
      Proof.
        intros pre post te e_trace Hl_pre Hl_post Hexp Ht.
        induction e_trace; inversion_ Hexp.
        - intros s s'' Hval Hpre.
          inversion_clear Hval.
          assert (Hss' : LongStep s [a] s').
          { apply ls_cons with (s' := s'); auto. constructor. }
          specialize (Ht s s' Hss' Hpre).
          specialize (hoare_nil post) as Hpost_post.
          specialize (expand_trace_nil post post e_trace Hl_post Hpost_post H5) as Hnil.
          specialize (Hnil s' s''); auto.
        - apply hoare_cons with (mid := pre); auto.
      Qed.

      (* This theorem is weaker than [expand_trace_elem], as it
      requires an additional assumption [ChainRuleLocality]. But
      on the other hand, it doesn't require [Local post] *)
      Theorem expand_trace : forall pre post trace trace',
          ChainRuleLocality ->
          Local pre ->
          ExpandedTrace trace trace' ->
          {{pre}} trace {{post}} ->
          {{pre}} trace' {{post}}.
      Proof.
        (* Human-readable proof: using [ChainRuleLocality] hypothesis,
        we can "pop up" all non-matching trace elements and get from a
        trace that looks like this:

        {---+---++---+--}

        to a one that looks like this:

        {-----------++++}

        Since our definition of commutativity gives us evidence that
        state transition between the commuting trace elements exists,
        we can conclude that there is a state transition from {----}
        part of trace to {++++}.
        *)
        intros pre post trace trace' Hcr Hl_pre Hexp Htrace.
        induction Hexp; auto.
        2:{ apply hoare_cons with (mid := pre); auto. }
        1:{ intros s e_s'' Hse_s'' Hpre.
            clear IHHexp.

            generalize dependent s.
            generalize dependent te.
            generalize dependent pre.
            induction Hexp; intros.
            - apply Htrace in Hse_s''. apply Hse_s'' in Hpre. assumption.
            - inversion_clear Hse_s''.
              set (mid := fun s' => chain_rule s s' te0) in *.
              apply IHHexp with (te := te) (s := s') (pre := mid); auto.
      Abort.

    End ExpandTrace.

    Section FrameRule.
      Theorem frame_rule : forall (e1 e2 : Ensemble TE) (P Q R : S -> Prop) (te : TE),
          Disjoint e1 e2 ->
          Local e1 P -> Local e1 Q -> Local e2 R ->
          In e1 te ->
          {{ P }} [te] {{ Q }} ->
          {{ fun s => P s /\ R s }} [te] {{ fun s => Q s /\ R s }}.
        Abort.
    End FrameRule.
  End defn.
End Hoare.

Section PossibleTrace.
  (** Property that tells if a certain sequence of side effects is
      "physically possible". E.g. mutex can't be taken twice, messages
      don't travel backwards in time, memory doesn't change all by
      itself and so on: *)
  Context {AID : Set} {H : @t AID}.

  Let S := h_state H.
  Let chain_rule := h_chain_rule H.

  Definition HoareTripleH (pre : S -> Prop) (trace : @Trace AID H) (post : S -> Prop) :=
    @HoareTriple AID H S chain_rule pre trace post.

  Definition PossibleTrace t :=
    exists s s', @LongStep AID H _ chain_rule s t s'.

  Notation "'{{' a '}}' t '{{' b '}}'" := (HoareTripleH a t b) : handler_scope.
End PossibleTrace.

Section ComposeHandlers.
  Context {AID : Set} `{OrderedType AID} (h_l h_r : @t AID).

  Let S_l := h_state h_l.
  Let S_r := h_state h_r.
  Let Q_l := h_req h_l.
  Let Q_r := h_req h_r.

  Definition compose_state : Set := S_l * S_r.
  Let S := compose_state.

  Definition compose_req : Set := Q_l + Q_r.
  Let Q := compose_req.

  Hint Transparent compose_state.

  Definition compose_initial_state state :=
    h_l.(h_initial_state) (fst state) /\ h_r.(h_initial_state) (snd state).

  Hint Transparent compose_initial_state.

  Definition compose_ret (req : Q) : Set :=
    match req with
    | inl l => h_l.(h_ret) l
    | inr r => h_r.(h_ret) r
    end.

  Check trace_elem.

  Inductive compose_chain_rule_i : S -> S -> @TraceElem_ AID Q compose_ret -> Prop :=
  | cmpe_left :
      forall (l l' : S_l) (r : S_r) aid req ret,
        h_chain_rule h_l l l' (trace_elem _ _ aid req ret) ->
        compose_chain_rule_i (l, r) (l', r) (trace_elem _ _ aid (inl req) ret)
  | cmpe_right :
      forall (r r' : S_r) (l : S_l) aid req ret,
        h_chain_rule h_r r r' (trace_elem _ _ aid req ret) ->
        compose_chain_rule_i (l, r) (l, r') (trace_elem _ _ aid (inr req) ret).

  Definition compose_chain_rule (s s' : S) (te : @TraceElem_ AID Q compose_ret) : Prop.
    destruct te as [aid req ret].
    destruct s as [l r].
    destruct s' as [l' r'].
    remember req as req0.
    destruct req;
      [ refine (r = r' /\ (h_chain_rule h_l) l l' _)
      | refine (l = l' /\ (h_chain_rule h_r) r r' _)
      ];
      apply trace_elem with (te_req := q);
      try apply aid;
      subst;
      unfold compose_ret in ret; easy.
  Defined.

  Definition compose : t :=
    {| h_state         := compose_state;
       h_req           := compose_req;
       h_ret           := compose_ret;
       h_initial_state := compose_initial_state;
       h_chain_rule    := compose_chain_rule;
    |}.

  Definition te_subset_l (te : @TraceElem AID compose) :=
    match te_req te with
    | inl _ => True
    | inr _ => False
    end.

  Definition te_subset_r (te : @TraceElem AID compose) :=
    match te_req te with
    | inl _ => False
    | inr _ => True
    end.

  Definition lift_l (prop : S_l -> Prop) : compose_state -> Prop :=
    fun s => match s with
            (s_l, _) => prop s_l
          end.

  Definition lift_r (prop : S_r -> Prop) : compose_state -> Prop :=
    fun s => match s with
            (_, s_r) => prop s_r
          end.

  Lemma lift_l_local : forall (prop : S_l -> Prop),
      @Local AID compose S compose_chain_rule te_subset_l (lift_l prop).
  Proof.
    unfold Local, HoareTriple.
    intros prop te Hin s s' Hte Hpre.
    unfold te_subset_l in Hin.
    destruct te as [aid req ret].
    unfold In in *.
    destruct req as [req|req]; simpl in *.
    - easy.
    - inversion_ Hte.
      unfold compose_chain_rule in H3.
      destruct s, s', s'0.
      firstorder.
      unfold eq_rec_r in *. simpl in *.
      subst.
      inversion_ H5.
  Qed.

  Lemma local_l_chain_rule : @ChainRuleLocality AID compose S
                                                compose_chain_rule te_subset_l.
  Proof.
    intros te1 te2 Hte1 Hte2 [l r] [l' r'].
    split; intros Hs';
    destruct te1 as [aid1 req1 ret1];
    destruct te2 as [aid2 req2 ret2];
    destruct req1, req2; unfold Ensembles.In, te_subset_l in *; try easy;
      clear Hte1; clear Hte2;
      inversion Hs' as [|[l1 r1] [l2 r2]]; subst; clear Hs';
      inversion H1 as [|[l3 r3] [l4 r4]]; subst; clear H1;
      inversion H3; subst; clear H3;
      unfold compose_chain_rule in *;
      firstorder; subst;
      unfold eq_rec_r in *; simpl in *.
    - apply ls_cons with (s' := (l, r')); firstorder.
      apply ls_cons with (s' := (l', r')); firstorder.
      constructor.
    - apply ls_cons with (s' := (l', r)); firstorder.
      apply ls_cons with (s' := (l', r')); firstorder.
      constructor.
  Qed.
End ComposeHandlers.

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

  Inductive mut_chain_rule : T -> T -> @TraceElem_ AID req_t ret_t -> Prop :=
  | mut_get : forall s aid,
      mut_chain_rule s s (trace_elem _ _ aid get s)
  | mut_put : forall s val aid,
      mut_chain_rule s val (trace_elem _ _ aid (put val) I).

  Definition t : t :=
    {|
      h_state := T;
      h_req := req_t;
      h_initial_state := initial_state;
      h_chain_rule := mut_chain_rule;
    |}.
  End defs.
End Mutable.

Module Mutex.
  Inductive req_t : Set :=
  | grab    : req_t
  | release : req_t.

  Local Definition ret_t (req : req_t) : Set :=
    match req with
    | grab => True
    | release => bool
    end.

  Section defs.
  Variable AID : Set.

  Definition state_t : Set := option AID.

  Inductive mutex_chain_rule : state_t -> state_t -> @TraceElem_ AID req_t ret_t -> Prop :=
  | mutex_grab : forall aid,
      mutex_chain_rule None (Some aid) (trace_elem _ _ aid grab I)
  | mutex_release_ok : forall aid,
      mutex_chain_rule (Some aid) None (trace_elem _ _ aid release true)
  | mutex_release_fail : forall aid,
      mutex_chain_rule (Some aid) None (trace_elem _ _ aid release false).

  Definition t : t :=
    {|
      h_state         := state_t;
      h_req           := req_t;
      h_initial_state := fun s0 => s0 = None;
      h_chain_rule    := mutex_chain_rule
    |}.

  Notation "aid '@' ret '<~' req" := (@trace_elem AID req_t ret_t aid req ret).

  Theorem no_double_grab_0 : forall (a1 a2 : AID),
      ~(@PossibleTrace AID t [a1 @ I <~ grab; a2 @ I <~ grab]).
  Proof.
    intros a1 a2 H.
    destruct H as [s [s' H]].
    inversion_ H.
    inversion_ H3.
    inversion_ H5.
    inversion_ H4.
  Qed.

  Theorem no_double_grab : forall (a1 a2 : AID),
      HoareTripleH
        (fun _ => True)
        ([a1 @ I <~ grab; a2 @ I <~ grab] : @Trace AID t)
        (fun _ => False).
  Proof.
    intros a1 a2 s s' Hss' Hpre.
    inversion_ Hss'.
    inversion_ H2.
    inversion_ H4.
    inversion_ H3.
  Qed.
  End defs.
End Mutex.

Section Actor.
  Context {AID : Set} `{AID_ord : OrderedType AID} {H : @t AID}.

  CoInductive Actor : Type :=
  | a_dead : Actor
  | a_cont :
      forall (pending_req : H.(h_req))
        (continuation : H.(h_ret) pending_req -> Actor)
      , Actor.

  Definition throw (_ : string) := a_dead.

End Actor.

Module ExampleModelDefn.
  Definition AID : Set := nat.

  Local Definition handler := compose (Mutable.t AID nat (fun a => a = 0))
                                      (Mutex.t AID).

  Notation "'do' V '<-' I ; C" := (@a_cont AID handler (I) (fun V => C))
                                    (at level 100, C at next level, V ident, right associativity).

  Notation "'done' I" := (@a_cont AID handler (I) (fun _ => a_dead))
                           (at level 100, right associativity).

  Notation "aid '@' ret '<~' req" := (trace_elem (h_req handler) (h_ret handler) aid req ret).

  Local Definition put (val : nat) : handler.(h_req) :=
    inl (Mutable.put val).

  Local Definition get : h_req handler :=
    inl (Mutable.get).

  Local Definition grab : h_req handler :=
    inr (Mutex.grab).

  Local Definition release : h_req handler :=
    inr (Mutex.release).

  (* Just a demonstration how to define a program that loops
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
End ExampleModelDefn.
