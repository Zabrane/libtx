From Coq Require Import
     List
     String
     Tactics
     Sets.Ensembles
     Program.Basics.

Export ListNotations.

From LibTx Require Import
     Permutation
     FoldIn.

Reserved Notation "'{{' a '}}' t '{{' b '}}'" (at level 40).
Reserved Notation "'{{}}' t '{{' b '}}'" (at level 39).

Global Arguments In {_}.
Global Arguments Complement {_}.
Global Arguments Disjoint {_}.

Ltac inversion_ a := inversion a; subst; auto with slot.

Class StateSpace (S TE : Type) :=
  { chain_rule : S -> S -> TE -> Prop;
  }.

Notation "a '~[' b ']~>' c" := (chain_rule a c b)(at level 40) : hoare_scope.
Infix "/\'" := (fun a b x => a x /\ b x)(at level 80) : hoare_scope.

Open Scope hoare_scope.

Section defn.
  Context {S : Type} {TE : Type} `{HSSp : StateSpace S TE}.

  Let T := list TE.

  Inductive LongStep : S -> T -> S -> Prop :=
  | ls_nil : forall s,
      LongStep s [] s
  | ls_cons : forall s s' s'' te trace,
      chain_rule s s' te ->
      LongStep s' trace  s'' ->
      LongStep s (te :: trace) s''.

  Hint Constructors LongStep : slot.

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

  Lemma ls_split : forall s s'' t1 t2,
      LongStep s (t1 ++ t2) s'' ->
      exists s', LongStep s t1 s' /\ LongStep s' t2 s''.
  Proof.
    intros.
    generalize dependent s.
    induction t1; intros.
    - exists s.
      split; auto with slot.
    - inversion_clear H.
      specialize (IHt1 s' H1).
      destruct IHt1.
      exists x.
      split.
      + apply ls_cons with (s' := s'); firstorder.
      + firstorder.
  Qed.

  Lemma ls_concat : forall s s' s'' t1 t2,
      LongStep s t1 s' ->
      LongStep s' t2 s'' ->
      LongStep s (t1 ++ t2) s''.
  Proof.
    intros.
    generalize dependent s.
    induction t1; intros; simpl; auto.
    - inversion_ H.
    - inversion_ H.
      apply ls_cons with (s' := s'0); auto.
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

  Lemma hoare_and : forall (A B C D : S -> Prop) (t : T),
      {{ A }} t {{ B }} ->
      {{ C }} t {{ D }} ->
      {{ fun s => A s /\ C s }} t {{ fun s => B s /\ D s }}.
  Proof. firstorder. Qed.

  Inductive TraceInvariant (prop : S -> Prop) : T -> Prop :=
  | inv_nil : TraceInvariant prop []
  | inv_cons : forall te t,
      {{prop}} [te] {{prop}} ->
      TraceInvariant prop t ->
      TraceInvariant prop (te :: t).

  Hint Constructors TraceInvariant : slot.

  Definition SystemInvariant (prop : S -> Prop) (E0 : Ensemble S) : Prop :=
    forall t,
      {{ E0 }} t {{ prop }}.

  Lemma trace_inv_split : forall prop t1 t2,
      TraceInvariant prop (t1 ++ t2) ->
      TraceInvariant prop t1 /\ TraceInvariant prop t2.
  Proof.
    intros.
    induction t1; split; auto with slot;
    inversion_ H; specialize (IHt1 H3);
    try constructor; firstorder.
  Qed.

  Lemma trace_inv_app : forall prop t1 t2,
      TraceInvariant prop t1 ->
      TraceInvariant prop t2 ->
      TraceInvariant prop (t1 ++ t2).
  Proof.
    intros.
    induction t1; simpl in *; auto with slot.
    inversion_ H.
  Qed.

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
    specialize (H s s');
    apply H in Hss';
    apply H0 in Hss';
    apply Hss' in Hpre;
    assumption.
  Qed.

  Lemma trace_elems_commute_symm : forall te1 te2,
      trace_elems_commute te1 te2 ->
      trace_elems_commute te2 te1.
  Proof. firstorder. Qed.

  Hint Resolve trace_elems_commute_symm : slot.

  Lemma trace_elems_commute_head : forall s s'' b a trace,
      trace_elems_commute a b ->
      LongStep s (b :: a :: trace) s'' ->
      LongStep s (a :: b :: trace) s''.
  Proof with auto with slot.
    intros.
    inversion_ H0.
    inversion_ H6.
    specialize (H s s'0).
    replace (a :: b :: trace) with ([a; b] ++ trace) by auto.
    apply ls_concat with (s' := s'0)...
    apply H.
    apply ls_cons with (s' := s')...
    apply ls_cons with (s' := s'0)...
  Qed.

  Lemma trace_elems_commute_head_ht : forall P Q b a trace,
      trace_elems_commute a b ->
      {{P}} b :: a :: trace {{Q}} ->
      {{P}} a :: b :: trace {{Q}}.
  Proof.
    intros. intros s s' Hls Hpre.
    apply trace_elems_commute_head in Hls.
    - apply (H0 s s' Hls Hpre).
    - now apply trace_elems_commute_symm.
  Qed.

  Definition trace_elems_commute_s te1 te2 s s' s'' :
    s ~[te1]~> s' ->
    s' ~[te2]~> s'' ->
    trace_elems_commute te1 te2 ->
    exists s'_, s ~[te2]~> s'_ /\ s'_ ~[te1]~> s''.
  Proof with auto.
    intros H1 H2 H.
    assert (Hls : LongStep s [te1; te2] s'').
    { apply ls_cons with (s' := s')...
      apply ls_cons with (s' := s'')...
      constructor.
    }
    apply H in Hls.
    inversion_ Hls.
    inversion_ H7.
    inversion_ H9.
    exists s'0.
    split...
  Qed.

  Lemma ht_comm_perm s s' t t' :
    LongStep s t s' ->
    Permutation trace_elems_commute t t' ->
    LongStep s t' s'.
  Proof with eauto with slot.
    intros Hls Hperm.
    induction Hperm.
    - trivial.
    - apply ls_split in IHHperm.
      destruct IHHperm as [s0 [Hss0 Hs0s']].
      apply trace_elems_commute_head in Hs0s'...
      eapply ls_concat...
  Qed.

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

    Let can_swap a b := In te_subset a /\ Complement te_subset b.

    Inductive ExpandedTrace (trace trace' : T) : Prop :=
      expanded_trace_ : forall expansion,
        Forall (Complement te_subset) expansion ->
        Permutation can_swap (expansion ++ trace) trace' ->
        ExpandedTrace trace trace'.

    Theorem expand_trace : forall pre post trace trace',
        ChainRuleLocality ->
        Local pre ->
        ExpandedTrace trace trace' ->
        {{pre}} trace {{post}} ->
        {{pre}} trace' {{post}}.
    Proof with auto with slot.
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
      intros pre post trace trace' Hcr Hl_pre [expansion Hcomp Hexp] Htrace.
      induction Hexp; intros; auto.
      2:{ intros s s'' Hss'' Hpre.
          apply ls_split in Hss''.
          destruct Hss'' as [s' [Hss' Hss'']].
          specialize (IHHexp s s'').
          specialize (Hcr a b).
          assert (Hls : LongStep s (l' ++ a :: b :: r') s'').
          { apply ls_concat with (s' := s')...
            apply trace_elems_commute_head...
            destruct H.
            apply Hcr...
          }
          apply IHHexp...
      }
      1:{ induction expansion.
          - easy.
          - simpl.
            inversion_ Hcomp.
            apply hoare_cons with (mid := pre).
            apply Hl_pre...
            firstorder.
      }
    Qed.
  End ExpandTrace.

  Theorem frame_rule : forall (e1 e2 : Ensemble TE) (P Q R : S -> Prop) (te : TE),
      Disjoint e1 e2 ->
      Local e2 R ->
      In e1 te ->
      {{ P }} [te] {{ Q }} ->
      {{ P /\' R }} [te] {{ Q /\' R }}.
  Proof.
    intros e1 e2 P Q R te He HlR Hin Hh.
    apply hoare_and.
    - assumption.
    - apply HlR.
      destruct He as [He].
      specialize (He te).
      unfold not, In in He.
      intros Hinte.
      apply He.
      constructor; auto.
  Qed.

  Definition PossibleTrace t :=
    exists s s', LongStep s t s'.
End defn.

Notation "'{{' a '}}' t '{{' b '}}'" := (HoareTriple a t b) : hoare_scope.
Notation "'{{}}' t '{{' b '}}'" := (HoareTriple (const True) t b) : hoare_scope.

Check ls_cons.

Ltac forward s' :=
  apply (ls_cons _ s' _ _ _).

Ltac resolve_concat :=
  match goal with
    [ H1 : LongStep ?s1 ?t1 ?s2, H2 : LongStep ?s2 ?t2 ?s3 |- LongStep ?s1 (?t1 ++ ?t2) ?s3] =>
    apply (ls_concat s1 s2 s3 t1 t2); assumption
  end.

Hint Extern 3 (LongStep _ (_ ++ _) _) => resolve_concat : slot.

Ltac long_step f tac :=
  cbn in f;
  lazymatch type of f with
  | LongStep _ [] _ =>
    let s := fresh "s" in
    let Hx := fresh "Hx" in
    let Hy := fresh "Hy" in
    let Hz := fresh "Hz" in
    inversion f as [s Hx Hy Hz|];
    subst s; clear f; clear Hy
  | LongStep _ (_ :: _) _ =>
    let s' := fresh "s" in
    let te := fresh "te" in
    let tail := fresh "tail" in
    let Hcr := fresh "Hcr" in
    let Htl := fresh "Htl" in
    inversion_clear f as [|? s' ? te tail Hcr Htl];
    rename Htl into f;
    cbn in Hcr;
    tac Hcr
  end.

Tactic Notation "long_step" ident(f) tactic3(tac) := long_step f tac.
Tactic Notation "long_step" ident(f) := long_step f (fun _ => idtac).

Ltac unfold_trace f tac :=
  repeat (long_step f tac).

Tactic Notation "unfold_trace" ident(f) tactic3(tac) := unfold_trace f tac.
Tactic Notation "unfold_trace" ident(f) := unfold_trace f (fun _ => idtac).

Ltac ls_advance tac :=
  match goal with
  | [H : LongStep ?s ?t ?s' |- ?Q ?s'] =>
    long_step H tac
  end.

Tactic Notation "ls_advance" tactic3(tac) := ls_advance tac.
Tactic Notation "ls_advance" := ls_advance (fun _ => idtac).

Hint Transparent Ensembles.In Ensembles.Complement : slot.
Hint Constructors LongStep : slot.
Hint Resolve trace_elems_commute_symm : slot.

Ltac unfold_ht :=
  match goal with
  | [ |- {{?pre}} ?t {{?post}}] =>
    let s := fresh "s_begin" in
    let s' := fresh "s_end" in
    let Hls := fresh "Hls" in
    let Hpre := fresh "Hpre" in
    intros s s' Hls Hpre;
    match eval cbn in Hpre with
    | [fun _ => True] => clear Hpre (* TODO: Fixme *)
    | _ => idtac
    end
  | _ =>
    fail "Goal does not look like a Hoare triple"
  end.

Section tests.
  Generalizable Variables ST TE.

  Goal forall `{StateSpace ST TE} s s' (te : TE), LongStep s [te; te; te] s' -> True.
    intros.
    unfold_trace H0.
  Abort.

  Goal forall `{StateSpace ST TE} s s' (te : TE), LongStep s [te] s' -> True.
    intros.
    unfold_trace H0 (fun x => try inversion x).
  Abort.

  Goal forall `{StateSpace ST TE} s s' (te : TE), LongStep s [] s' -> True.
    intros.
    unfold_trace H0.
  Abort.

  Goal forall `{StateSpace ST TE} pre post l, {{pre}} (l: list TE) {{post}}.
    intros.
    unfold_ht.
  Abort.
End tests.
