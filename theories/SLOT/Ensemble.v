From Coq Require Import
     List.

From LibTx Require Import
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

  Definition EHoareTriple (pre : S -> Prop) (g : TraceEnsemble) (post : S -> Prop) :=
    forall t, g t ->
         {{ pre }} t {{ post}}.

  Inductive TraceEnsembleConcat (e1 e2 : TraceEnsemble) : TraceEnsemble :=
  | et_concat : forall t1 t2, e1 t1 -> e2 t2 -> TraceEnsembleConcat e1 e2 (t1 ++ t2).

  Inductive Interleaving : T -> T -> TraceEnsemble :=
  | ilv_cons_l : forall te t1 t2 t,
      Interleaving t1 t2 t ->
      Interleaving (te :: t1) t2 (te :: t)
  | ilv_cons_r : forall te t1 t2 t,
      Interleaving t1 t2 t ->
      Interleaving t1 (te :: t2) (te :: t)
  | ilv_nil_l : forall t2,
      Interleaving [] t2 t2
  | ilv_nil_r : forall t1,
      Interleaving t1 [] t1.

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
      - exists t2. exists []. exists []...
      - exists t1. exists []. exists t1...
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
      induction t1; simpl; auto.
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
      induction t1...
    Qed.

    Lemma interleaving_nil_r : forall (a b : list TE),
        Interleaving a b [] ->
        a = [] /\ b = [].
    Proof.
      intros.
      remember [] as t.
      destruct H; try discriminate; firstorder.
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
      induction H as [te ab c t H IH| te ab c t H IH| | ]; intros.
      - destruct a; [destruct b; inversion_ Heqab | idtac]; simpl in *.
        + exists []. exists c. exists []. exists (t0 :: t)...
        + inversion Heqab. subst.
          specialize (IH a b eq_refl).
          destruct IH as [c1 [c2 [t1 [t2 [Ht [Ht2 [Hint1 Hint2]]]]]]]; subst.
          exists c1. exists c2. exists (t0 :: t1). exists t2...
      - specialize (IH a b Heqab).
        destruct IH as [c1 [c2 [t1 [t2 [Ht [Ht2 [Hint1 Hint2]]]]]]]; subst.
        exists (te :: c1). exists c2. exists (te :: t1). exists t2...
      - symmetry in Heqab. apply app_eq_nil in Heqab...
        subst.
        exists []. exists t2. exists []. exists t2...
      - exists []. exists []. exists a. exists b...
    Qed.

    Lemma e_hoare_inv_par_seq : forall e1 e2 e prop,
        EnsembleInvariant prop (e1 -|| e) ->
        EnsembleInvariant prop (e2 -|| e) ->
        EnsembleInvariant prop (e1 ->> e2 -|| e).
    Proof.
      intros.
      intros t Ht.
      destruct Ht as [t12 c t Ht12 Hc Hint].
      destruct Ht12 as [a b Ha Hb].
      apply interleaving_par_seq in Hint.
      destruct Hint as [c__hd [c__tl [t__hd [t__tl [Ht [Hcc [Hhd Htl]]]]]]].
      specialize (H (t__hd ++ c__tl)). apply trace_inv_split in H.
      specialize (H0 (c__hd ++ t__tl)). apply trace_inv_split in H0.
      subst.
      apply trace_inv_app; firstorder.
      - apply ilv_par with (t1 := b) (t2 := c); auto.
        subst.
        apply interl_app_tl; assumption.
      - apply ilv_par with (t1 := a) (t2 := c); auto.
        subst.
        apply interl_app_hd; assumption.
    Qed.

    Lemma e_hoare_inv_par_par : forall e1 e2 e prop,
        EnsembleInvariant prop (e1 -|| e) ->
        EnsembleInvariant prop (e2 -|| e) ->
        EnsembleInvariant prop ((e1 -|| e2) -|| e).
    Abort.

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
