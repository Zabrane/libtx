(** * Ensembles of traces

    Trace ensembles play one of central roles in SLOT, because from
    SLOT point of view any system is nothing but a collection of event
    traces that it can produce.

 *)
From Coq Require Import
     Program.Basics
     List.

From LibTx Require Import
     Misc
     EventTrace
     Permutation
     SLOT.Hoare.

Import ListNotations.

Open Scope hoare_scope.

Section defn.
  Context {S TE} `{StateSpace S TE}.
  Let T := list TE.

  Definition TraceEnsemble := T -> Prop.

  Class Generator (A : Type) :=
    { unfolds_to : A -> TraceEnsemble;
    }.

  (** Hoare logic of trace ensembles consists of a single rule: *)
  Definition EHoareTriple (pre : S -> Prop) (g : TraceEnsemble) (post : S -> Prop) :=
    forall t, g t ->
         {{ pre }} t {{ post}}.

  (** Concatenation of trace ensembles represents systems that run
  sequentially: *)
  Inductive TraceEnsembleConcat (e1 e2 : TraceEnsemble) : TraceEnsemble :=
  | et_concat : forall t1 t2, e1 t1 -> e2 t2 -> TraceEnsembleConcat e1 e2 (t1 ++ t2).

  (** Set of all possible interleaving of two traces is a trace
  ensemble: *)
  Inductive Interleaving : T -> T -> TraceEnsemble :=
  | ilv_cons_l : forall te t1 t2 t,
      Interleaving t1 t2 t ->
      Interleaving (te :: t1) t2 (te :: t)
  | ilv_cons_r : forall te t1 t2 t,
      Interleaving t1 t2 t ->
      Interleaving t1 (te :: t2) (te :: t)
  | ilv_nil : Interleaving [] [] [].

  (** Two systems running in parallel are represented by interleaving
  of all possible traces that could be produced by these systems: *)
  Inductive Parallel (e1 e2 : TraceEnsemble) : TraceEnsemble :=
  | ilv_par : forall t1 t2 t,
      e1 t1 -> e2 t2 ->
      Interleaving t1 t2 t ->
      Parallel e1 e2 t.

  Definition EnsembleInvariant (prop : S -> Prop) (E : TraceEnsemble) : Prop :=
    forall (t : T), E t -> TraceInvariant prop t.
End defn.

Hint Constructors Interleaving Parallel.

Notation "'-{{' a '}}' t '{{' b '}}'" := (EHoareTriple a t b)(at level 40) : hoare_scope.
Infix "->>" := (TraceEnsembleConcat) (at level 100) : hoare_scope.
Infix "-||" := (Parallel) (at level 101) : hoare_scope.

Section props.
  Context {S TE} `{HsspS : StateSpace S TE}.
  Let T := list TE.

  (* Lemma ensemble_invariant_sublist : forall prop E a b c, *)
  (*     a ++ b = c -> *)
  (*     E c -> *)
  (*     EnsembleInvariant prop E -> *)
  (*     EnsembleInvariant prop E a. *)

  Lemma e_hoare_concat : forall pre mid post e1 e2,
      -{{pre}} e1 {{mid}} ->
      -{{mid}} e2 {{post}} ->
      -{{pre}} e1 ->> e2 {{post}}.
  Proof.
    intros *. intros H1 H2 t Ht.
    destruct Ht.
    apply hoare_concat with (mid0 := mid); auto.
  Qed.

  Section perm_props.
    Lemma interleaving_symm : forall {TE} (t1 t2 t : list TE),
      Interleaving t1 t2 t ->
      Interleaving t2 t1 t.
    Proof.
      intros.
      induction H; constructor; auto.
    Qed.

    Lemma interleaving_nil : forall {ctx} t1 t2,
        @Interleaving ctx [] t1 t2 ->
        t1 = t2.
    Proof.
      intros.
      remember [] as t.
      induction H; subst; try easy.
      rewrite IHInterleaving; auto.
    Qed.

    Lemma interleaving_par_head : forall (t1 t2 t : list TE),
        Interleaving t1 t2 t ->
        exists t' t1_hd t1_tl,
          t = t1_hd ++ t' /\ t1 = t1_hd ++ t1_tl /\ Interleaving t1_tl t2 t'.
    Proof with firstorder.
      intros *. intros Hint.
      induction Hint.
      - destruct IHHint as [t' [t1_hd [t1_tl IH]]].
        exists t'. exists (te :: t1_hd). exists (t1_tl).
        firstorder; subst; reflexivity.
      - exists (te :: t). exists []. exists t1...
      - exists []. exists []. exists []...
    Qed.

    Lemma e_hoare_par_ergo_seq : forall e1 e2 P Q,
      -{{P}} e1 -|| e2 {{Q}} ->
      -{{P}} e1 ->> e2 {{Q}}.
    Proof.
      intros. intros t Hseq.
      specialize (H t). apply H. clear H.
      destruct Hseq as [t1 t2].
      apply ilv_par with (t3 := t1) (t4 := t2); auto.
      clear H H0.
      induction t1; induction t2; simpl; auto.
    Qed.

    Lemma e_hoare_par_symm : forall e1 e2 P Q,
        -{{P}} e1 -|| e2 {{Q}} ->
        -{{P}} e2 -|| e1 {{Q}}.
    Proof.
      intros. intros t Hpar.
      specialize (H t). apply H. clear H.
      destruct Hpar as [t1 t2 t H1 H2 Hint].
      apply interleaving_symm in Hint.
      apply ilv_par with (t3 := t2) (t4 := t1); easy.
    Qed.

    Lemma interl_app_tl : forall (b c__hd c__tl t : list TE),
        Interleaving b c__tl t ->
        Interleaving b (c__hd ++ c__tl) (c__hd ++ t).
    Proof.
      intros.
      induction c__hd; simpl; auto.
    Qed.

    Lemma interl_app_hd : forall (a c__hd c__tl t : list TE),
        Interleaving a c__hd t ->
        Interleaving a (c__hd ++ c__tl) (t ++ c__tl).
    Proof with simpl; auto.
      intros.
      induction H...
      induction c__tl...
    Qed.

    Lemma interleaving_nil_r : forall (a b : list TE),
        Interleaving a b [] ->
        a = [] /\ b = [].
    Proof.
      intros.
      remember [] as t.
      destruct H; try discriminate; firstorder.
    Qed.

    Theorem e_hoare_inv_par : forall e1 e2 prop,
        EnsembleInvariant prop e1 ->
        EnsembleInvariant prop e2 ->
        EnsembleInvariant prop (e1 -|| e2).
    Proof with constructor; auto.
      intros e1 e2 prop He1 He2.
      intros t [t1 t2 t12 Ht1 Ht2 Hint].
      specialize (He1 t1 Ht1). clear Ht1.
      specialize (He2 t2 Ht2). clear Ht2.
      induction Hint; try assumption.
      - inversion_ He1...
      - inversion_ He2...
    Qed.

    Lemma e_hoare_inv_seq : forall e1 e2 prop,
        EnsembleInvariant prop e1 ->
        EnsembleInvariant prop e2 ->
        EnsembleInvariant prop (e1 ->> e2).
    Proof.
      intros e1 e2 prop He1 He2.
      intros t [t1 t2 Ht1 Ht2].
      specialize (He1 t1 Ht1). clear Ht1.
      specialize (He2 t2 Ht2). clear Ht2.
      induction t1.
      - easy.
      - inversion He1.
        constructor; auto.
    Qed.

    Lemma interleaving_par_seq : forall (a b c t : list TE),
        Interleaving (a ++ b) c t ->
        exists c1 c2 t1 t2,
          t1 ++ t2 = t /\ c1 ++ c2 = c /\
          Interleaving a c1 t1 /\ Interleaving b c2 t2.
    Proof with firstorder.
      intros.
      remember (a ++ b) as ab.
      generalize dependent b.
      generalize dependent a.
      induction H as [te ab c t H IH| te ab c t H IH| ]; intros.
      - destruct a; [destruct b; inversion_ Heqab | idtac]; simpl in *.
        + exists []. exists c. exists []. exists (t0 :: t)...
        + inversion Heqab. subst.
          specialize (IH a b eq_refl).
          destruct IH as [c1 [c2 [t1 [t2 [Ht [Ht2 [Hint1 Hint2]]]]]]]; subst.
          exists c1. exists c2. exists (t0 :: t1). exists t2...
      - specialize (IH a b Heqab).
        destruct IH as [c1 [c2 [t1 [t2 [Ht [Ht2 [Hint1 Hint2]]]]]]]; subst.
        exists (te :: c1). exists c2. exists (te :: t1). exists t2...
      - symmetry in Heqab. apply app_eq_nil in Heqab.
        destruct Heqab. subst.
        exists []. exists []. exists []. exists []...
    Qed.

    Lemma e_hoare_par_seq1 : forall e1 e2 e P Q,
        (* -{{P}} e1 -|| e {{Q}} -> *)
        (* -{{Q}} e2 -|| e {{Q}} -> *)
        (* -{{P}} e1 ->> e2 {{Q}} -> *)
        -{{P}} e1 ->> e2 -|| e {{Q}}.
    Proof.
      intros *. (* intros Hpar1 Hpar2 Hseq. *)
      intros t Ht.
      destruct Ht as [t12 t_ t H12 Ht_ Hint].
      destruct H12 as [t1 t2 H1 H2].
      (*   t_, t, t1, t2 : list TE
           H1 : e1 t1
           H2 : e2 t2
           Ht_ : e t_
           Hint : Interleaving (t1 ++ t2) t_ t
       *)
    Abort.

    Lemma e_hoare_par_seq : forall e1 e2 e P Q R,
        -{{P}} e1 -|| e {{Q}} ->
        -{{Q}} e2 -|| e {{R}} ->
        -{{P}} e1 ->> e2 -|| e {{R}}.
    Proof.
      intros *. intros H1 H2 t Ht s s' Hss' Hpre.
      destruct Ht as [t1 t2 t Ht1 Ht2 Hint].
    Abort. (* This is wrong? *)
  End perm_props.
End props.

Ltac clear_equations :=
  repeat match goal with
           [H: ?a = ?a |- _] => clear H
         end.

Ltac destruct_interleaving H :=
  match type of H with
    Interleaving ?a ?b ?c =>
    let a0 := fresh in
    let b0 := fresh in
    let Ha := fresh in
    let Hb := fresh in
    remember a as a0 eqn:Ha; remember b as b0 eqn:Hb;
    destruct H; inversion Ha; inversion Hb; subst; try discriminate;
    clear_equations
  end.

Ltac unfold_interleaving H tac :=
  simpl in H;
  lazymatch type of H with
  | Interleaving [] _ _ =>
    apply interleaving_nil in H;
    rewrite <-H in *; clear H;
    repeat tac
  | Interleaving _ [] _ =>
    apply interleaving_symm, interleaving_nil in H;
    rewrite <-H in *; clear H;
    repeat tac
  | Interleaving ?tl ?tr ?t =>
    let te := fresh "te" in
    let tl' := fresh "tl" in
    let tr' := fresh "tr" in
    let t := fresh "t" in
    (* stuff that we need in order to eliminate wrong hypotheses *)
    let tl0 := fresh "tl" in let Htl0 := fresh "Heql" in remember tl as tl0 eqn:Htl0;
    let tr0 := fresh "tr" in let Htr0 := fresh "Heqr" in remember tr as tr0 eqn:Htr0;
    destruct H as [te tl' tr' t H | te tl' tr' t H |];
    repeat (match goal with
            | [H : _ :: _ = _ |- _] =>
              inversion H; subst; clear H
            end);
    try discriminate;
    subst;
    tac;
    unfold_interleaving H tac
  | ?err =>
    fail "Not an unfoldable interleaving" err
  end.

Tactic Notation "unfold_interleaving" ident(H) "with" tactic(tac) :=
  unfold_interleaving H tac.

Tactic Notation "unfold_interleaving" ident(H) :=
  unfold_interleaving H with idtac.

Ltac interleaving_nil :=
  repeat match goal with
         | [H: Interleaving [] ?t1 ?t |- _] => apply interleaving_nil in H
         | [H: Interleaving ?t1 [] ?t |- _] => apply interleaving_symm, interleaving_nil in H
         end.

Hint Extern 4 => interleaving_nil.

Section permutation.
  Context {S PID Req : Type} {Ret : Req -> Type}.
  Let TE := @TraceElem PID Req Ret.
  Context `{HsspS : StateSpace S TE}.

  Definition can_swap (a b : TE) : Prop :=
    te_pid a <> te_pid b.

  Definition DoubleForall {X} (f : X -> X -> Prop) (l1 l2 : list X) : Prop :=
    Forall (fun a => (Forall (f a) l1)) l2.

  Lemma DoubleForall_drop {X} f (a : X) l1 l2 :
    Forall (fun a0 : X => Forall (f a0) (a :: l1)) l2 ->
    Forall (fun a0 : X => Forall (f a0) l1) l2.
  Admitted. (* TODO *)
  (* assert (Htail : Forall (fun a : TE => Forall (can_swap a) t2) t1). *)
  (* { clear IHInterleaving. clear H. *)
  (*   induction t1. *)
  (*   - easy. *)
  (*   - constructor. *)
  (*     + now apply Forall_inv,Forall_inv_tail in Hdisjoint. *)
  (*     + apply Forall_inv_tail in Hdisjoint. *)
  (*       now apply IHt1. *)
  (* } *)

  Lemma DoubleForall_symm {X} f (l1 l2 : list X) :
    DoubleForall f l1 l2 -> DoubleForall f l2 l1.
  Admitted. (* TODO *)

  Lemma interleaving_to_permutation t1 t2 t :
    Forall (fun a => Forall (can_swap a) t2) t1 ->
    Interleaving t1 t2 t ->
    @Permutation _ can_swap (t1 ++ t2) t.
  Proof.
    intros Hdisjoint H.
    induction H.
    3:{ simpl. constructor. }
    { apply Forall_inv_tail in Hdisjoint.
      now apply perm_cons, IHInterleaving.
    }
    { specialize (DoubleForall_drop can_swap te t2 t1 Hdisjoint) as Htail.
      specialize (IHInterleaving Htail). clear Htail. clear H.
      apply DoubleForall_symm, Forall_inv in Hdisjoint.
      apply perm_cons with (a := te) in IHInterleaving.
      induction IHInterleaving; try now constructor.
      induction t1.
      - constructor.
      - specialize (perm_shuf can_swap ((a :: t1) ++ te :: t2) [] (t1 ++ t2) a te) as Hs.
        simpl in *.
        apply Hs.
        + apply perm_cons, IHt1.
          now apply Forall_inv_tail in Hdisjoint.
        + apply Forall_inv in Hdisjoint.
          symm_not. apply Hdisjoint.
    }
  Qed.
End permutation.

Section comm_domains.
  (** ** Definitions that are needed mostly to reduce complexity of bruteforce tactic *)
  Context {S PID Req : Type} {Ret : Req -> Type}.
  Let TE := @TraceElem PID Req Ret.
  Context `{HsspS : StateSpace S TE}.
  Let T := list TE.

  Definition domains_commute (dom1 dom2 : T) :=
    match dom1, dom2 with
    | [], _ => True
    | _, [] => True
    | (te1 :: dom1), (te2 :: dom2) =>
      DoubleForall trace_elems_commute dom1 dom2 /\
      Forall (fun a => trace_elems_commute a te2) dom1 /\
      Forall (fun a => trace_elems_commute a te1) dom2
    end.

  Lemma ilv_dom_comm dom1 dom2 P Q :
    domains_commute dom1 dom2 ->
    {{P}} dom1 ++ dom2 {{Q}} -> {{P}} dom2 ++ dom1 {{Q}} ->
    -{{P}} Interleaving dom1 dom2 {{Q}}.
  Proof.
    intros Hcomm H1 H2 t Ht. unfold_ht.
    specialize (fun H => H1 s_begin s_end H Hpre).
    specialize (fun H => H2 s_begin s_end H Hpre).
    clear Hpre.
    destruct dom1 as [|te1 t1], dom2 as [|te2 t2];
      simpl in *;
      interleaving_nil;
      autorewrite with list in *;
      subst;
      try now apply H1.
    replace (te1 :: t1 ++ te2 :: t2) with ((te1 :: t1) ++ te2 :: t2) in H1 by auto.
    replace (te2 :: t2 ++ te1 :: t1) with ((te2 :: t2) ++ te1 :: t1) in H2 by auto.
    apply interleaving_to_permutation in Ht.
    remember (te1 :: t1) as t1_.
    remember (te2 :: t2) as t2_.
    destruct Ht; subst.
  Abort.

  Inductive CommDomains :=
  | commd_nil :
      CommDomains
  | commd_cons : forall dom_l dom_r,
      domains_commute dom_l dom_r ->
      CommDomains ->
      CommDomains.

  Inductive CommInterleaving : CommDomains -> TraceEnsemble :=
  | cilv_nil :
      CommInterleaving commd_nil []
  | cilv_l : forall dom_l dom_r H rest t,
      CommInterleaving rest t ->
      CommInterleaving (commd_cons dom_l dom_r H rest)
                       (dom_l ++ dom_r ++ t)
  | cilv_r : forall dom_l dom_r H rest t,
      CommInterleaving rest t ->
      CommInterleaving (commd_cons dom_l dom_r H rest)
                       (dom_r ++ dom_l ++ t).

  Inductive flatten_comm_domains : CommDomains -> T -> T -> Prop :=
  | fltcd_nil : flatten_comm_domains commd_nil [] []
  | fltcd_cons : forall dom1 dom2 Hcomm t1 t2 rest,
      flatten_comm_domains rest t1 t2 ->
      flatten_comm_domains (commd_cons dom1 dom2 Hcomm rest)
                           (dom1 ++ t1)
                           (dom2 ++ t2).

  Lemma interleaving_to_comm_domains t1 t2 doms P Q :
    flatten_comm_domains doms t1 t2 ->
    -{{P}} CommInterleaving doms {{Q}} ->
    -{{P}} Interleaving t1 t2 {{Q}}.
  Proof.
    intros Hdoms Hcinv t Ht.
    unfold_ht.
    specialize (fun H => Hcinv t H s_begin s_end Hls Hpre).
    clear Hpre. clear Hls. clear P.
    induction Ht.
    -
  Abort.

  Goal forall P Q R (x11 x12 x21 x22 x31 x32 : TE) (t12 t23 t13 t123 : list TE),
      let t1 := [x11(* ; x12 *)] in
      let t2 := [x21(* ; x22 *)] in
      let t3 := [x31(* ; x32 *)] in
      Interleaving t1 t2 t12 ->
      Interleaving t1 t3 t13 ->
      {{P}} t12 {{Q}} ->
      {{Q}} t13 {{R}} ->
      Interleaving t12 t3 t123 ->
      {{P}} t123 {{Q}}.
  Proof.
    intros.
    unfold_ht.
(*     repeat match goal with *)
      (*      | [H : Interleaving _ _ _ |- _] => unfold_interleaving H *)
      (*      (* | [H : {{_}} ?t {{_}} |- _] => unfold_ht H *) *)
      (*      end; *)
      (* subst t1 t2 t3. *)
  Abort.
End comm_domains.
