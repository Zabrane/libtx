Require Import String.
Require Import List.
Require Import Coq.Program.Basics.
Require FMapAVL.
Import ListNotations.
Import Decidable.
Import Sumbool.

Set Implicit Arguments.


Ltac symm_not :=
  let H := fresh
  in unfold not;
     intros H;
     symmetry in H;
     generalize dependent H.

Module Storage.

Definition TabName := String.string.

Reserved Notation "s1 =s= s2" (at level 50).

Module Type Interface.
  (* We assume that all operations listed here are atomic and it's up
  to the storage backend to ensure this property *)

  Parameter Storage : Type -> Type -> Type.

  Parameter new : forall {K V : Type}, Storage K V.

  Parameter put : forall {K V : Type}, K -> V -> Storage K V -> Storage K V.

  Parameter get : forall {K V : Type}, K -> Storage K V -> option V.

  Parameter keys : forall {K V : Type}, Storage K V -> list K.

  Parameter delete : forall {K V : Type}, K -> Storage K V -> Storage K V.

  Axiom new_empty : forall {K V : Type} k,
      get k (new : Storage K V) = None.

  Axiom keep : forall {K V : Type} (s : Storage K V) (k : K) (v : V),
      get k (put k v s) = Some v.

  Axiom distinct : forall {K V : Type} (s : Storage K V) (k1 : K) (k2 : K) (v2 : V),
      k1 <> k2 ->
      get k1 s = get k1 (put k2 v2 s).

  Axiom delete_keep : forall {K V : Type} (s : Storage K V) k,
      get k (delete k s) = None.

  Axiom delete_distinct : forall {K V : Type} (s : Storage K V) (k1 : K) (k2 : K),
      k1 <> k2 ->
      get k1 s = get k1 (delete k2 s).

  Axiom keys_some : forall {K V : Type} (s : Storage K V) k,
      In k (keys s) -> exists v, get k s = Some v.

  Axiom keys_none : forall {K V : Type} (s : Storage K V) k,
      ~In k (keys s) -> get k s = None.

End Interface.

Module Equality (I : Interface).
  Import I.

  Inductive s_eq {K V : Type} (s1 : Storage K V) (s2 : Storage K V) :=
  | s_eq_ : (forall k, get k s1 = get k s2) -> s_eq s1 s2.

  Notation "s1 =s= s2" := (s_eq s1 s2) (at level 50).

  Lemma s_eq_self : forall {K V} (s : Storage K V), s =s= s.
  Proof.
    intros.
    assert (H: forall k, get k s = get k s).
    { intros. reflexivity. }
    apply (s_eq_ H).
  Qed.

  Lemma new_keys_empty : forall {K V}, keys (@new K V) = [].
  Proof.
    intros.
    remember (keys new) as k.
    destruct k.
    - reflexivity.
    - assert (Hk : In k (keys (@new K V))).
      { rewrite <-Heqk. apply in_eq. }
      apply keys_some in Hk.
      destruct Hk as [v nonsense].
      specialize (@new_empty K V k) as empty.
      rewrite nonsense in empty.
      easy.
  Qed.

  Lemma put_eq_eq : forall {K V} (s1 s2 : Storage K V) k v,
      (forall k1 k2 : K, {k1 = k2} + {k1 <> k2}) ->
      s1 =s= s2 ->
      put k v s1 =s= put k v s2.
  Proof.
    intros K V s1 s2 k v Heq_dec Heq.
    constructor.
    intros x.
    destruct (Heq_dec x k) as [H|H].
    - subst. repeat rewrite keep. reflexivity.
    - repeat rewrite <-(@distinct _ _ _ x k v H).
      destruct Heq as [Heq]. apply Heq.
  Qed.

  Lemma put_same : forall {K V} (s : Storage K V) k v,
      (forall k1 k2 : K, {k1 = k2} + {k1 <> k2}) ->
      get k s = Some v ->
      s =s= put k v s.
  Proof.
    intros K V s k v K_eq_dec Hkv.
    constructor.
    intros x.
    destruct (K_eq_dec x k) as [H|H].
    - subst. rewrite keep, Hkv. reflexivity.
    - rewrite <-(@distinct _ _ _ x k v H). reflexivity.
  Qed.

  Lemma put_distict_comm : forall {K V} (s : Storage K V) k1 k2 v1 v2,
      (forall k1 k2 : K, {k1 = k2} + {k1 <> k2}) ->
      k1 <> k2 ->
      put k2 v2 (put k1 v1 s) =s= put k1 v1 (put k2 v2 s).
  Proof.
    intros K V s k1 k2 v1 v2 Keq_dec H12.
    apply s_eq_.
    intros k.
    destruct (Keq_dec k k1) as [|Hnk1]; subst.
    - rewrite <-(@distinct _ _ _ k1 k2 v2 H12).
      repeat rewrite keep.
      reflexivity.
    - destruct (Keq_dec k k2) as [|Hnk2]; subst.
      + rewrite <-(@distinct _ _ _ k2 k1 _ Hnk1).
        repeat rewrite keep.
        reflexivity.
      + repeat ( rewrite <-(@distinct _ _ _ k _ _ Hnk1)
               || rewrite <-(@distinct _ _ _ k _ _ Hnk2)).
        reflexivity.
  Qed.

End Equality.

Module WriteLog (I : Interface).
  Import I.
  Module IE := Equality I.
  Import IE.

  Inductive Wlog_en {K V} :=
  | wl_w : K -> V -> Wlog_en
  | wl_d : K -> Wlog_en.

  Definition Wlog_en_apply {K V} (s : Storage K V) (l : @Wlog_en K V) :
    Storage K V :=
    match l with
    | wl_w k v => put k v s
    | wl_d k => delete k s
    end.

  Definition Wlog {K V} := list (@Wlog_en K V).

  Definition Wlog_apply {K V} (l : @Wlog K V) (s : Storage K V) :=
    fold_left Wlog_en_apply l s.

  Definition Wlog_has_key {K V} (k : K) (l : @Wlog K V) : Prop :=
    In k (map (fun x => match x with
                     | wl_w k _ => k
                     | wl_d k => k
                     end) l).

  (* D'oh! This _should_ be somewhere in the standard library... *)
  Lemma sumbool_dec : forall A, { A } + { ~ A } ->
                           decidable A.
  Proof.
    intros A H.
    destruct H; [left | right]; assumption.
  Qed.

  Lemma Wlog_has_key_dec : forall {K V} k (l : @Wlog K V),
      (forall k1 k2 : K, {k1 = k2} + {k1 <> k2}) ->
      decidable (Wlog_has_key k l).
  Proof.
    intros K V k l Keq_dec.
    unfold Wlog_has_key.
    induction l as [|e t IH]; simpl.
    - apply dec_False.
    - apply dec_or.
      + apply sumbool_dec, Keq_dec.
      + apply IH.
  Qed.

  Inductive Wlog_nodup {K V} : @Wlog K V ->
                               @Wlog K V ->
                               Prop :=
  | wse0 : Wlog_nodup [] []
  | wse1 : forall l l' t k v,
      l = (wl_w k v) :: t ->
      ~Wlog_has_key k t ->
      Wlog_nodup t l' ->
      Wlog_nodup l ((wl_w k v) :: l')
  | wse2 : forall l l' t k,
      l = (wl_d k) :: t ->
      ~Wlog_has_key k t ->
      Wlog_nodup t l' ->
      Wlog_nodup l ((wl_d k) :: l').

  Lemma Wlog_has_key_rev : forall {K V} (l : @Wlog K V) k,
      Wlog_has_key k l <-> Wlog_has_key k (rev l).
  Proof.
    intros K V l k.
    unfold Wlog_has_key.
    rewrite map_rev.
    apply in_rev.
  Qed.

  Ltac wlog_app_simpl_ NEQ :=
    simpl; unfold Wlog_apply;
    repeat rewrite fold_left_app;
    simpl;
    subst;
    repeat rewrite keep;
    repeat rewrite <-distinct by NEQ;
    repeat rewrite delete_keep;
    repeat rewrite <-delete_distinct by NEQ.

  Tactic Notation "wlog_app_simpl" "by" tactic2(x) :=
    wlog_app_simpl_ x.

  Tactic Notation "wlog_app_simpl" :=
    wlog_app_simpl_ fail.

  Hint Constructors s_eq.

  Ltac unfold_s_eq k :=
    constructor;
    intros k.

  Ltac unfold_s_eq_in k :=
    destruct k as [k].

  Tactic Notation "unfold_s_eq" "in" ident(k) :=
    unfold_s_eq_in k.

  Tactic Notation "unfold_s_eq" "as" ident(k) :=
    unfold_s_eq k.

  Ltac rev_wlog_induction l k v t IH :=
    rewrite <-(rev_involutive l) in *;
    induction (rev l) as [|[k v|k] t IH]; try easy.

  Tactic Notation "rev_wlog_induction" hyp(l) "as" ident(k) ident(v) ident(t) ident(IH) :=
    rev_wlog_induction l k v t IH.

  Ltac has_key_rev_simpl H :=
    simpl in H;
    rewrite Wlog_has_key_rev, rev_app_distr, rev_involutive in H;
    simpl in H;
    unfold Wlog_has_key in H;
    simpl in H.

  Tactic Notation "has_key_rev_simpl" "in" hyp(H) := has_key_rev_simpl H.

  Hint Unfold Wlog_apply.
  Hint Unfold Wlog_has_key.

  Hint Extern 3 => symm_not.
  Hint Extern 4 => rewrite <-Wlog_has_key_rev.
  Hint Extern 4 => rewrite keep.
  Hint Extern 4 => rewrite delete_keep.
  Hint Resolve s_eq_self.

  Lemma Wlog_apply_same : forall {K V} (l : @Wlog K V) (s1 s2 : Storage K V),
      (forall k1 k2 : K, {k1 = k2} + {k1 <> k2}) ->
      s1 =s= s2 ->
      Wlog_apply l s1 =s= Wlog_apply l s2.
  Proof.
    intros K V l s1 s2 Keq_dec H.
    rev_wlog_induction l as k v t IH;
      unfold_s_eq in IH;
      unfold_s_eq as k';
      destruct (Keq_dec k' k) as [Hkk|Hkk];
      wlog_app_simpl by apply Hkk;
      easy.
  Qed.

  Lemma Wlog_ignore : forall {K V} (l : @Wlog K V) s k,
      ~ Wlog_has_key k l ->
      get k s = get k (Wlog_apply l s).
  Proof.
    intros K V l s k H.
    rev_wlog_induction l as k' _v t IH;
      unfold Wlog_apply in IH;
      wlog_app_simpl;
      has_key_rev_simpl in H;
      [rewrite <-distinct by auto | rewrite <-delete_distinct by auto];
      firstorder;
      rewrite <-IH;
      auto.
  Qed.

  Lemma Wlog_ignore_cons : forall {K V} (l : @Wlog K V) s k1 k2 v,
      (forall k1 k2 : K, {k1 = k2} + {k1 <> k2}) ->
      k1 <> k2 ->
      get k1 (Wlog_apply l (put k2 v s)) = get k1 (Wlog_apply l s).
  Proof.
    intros K V l s k1 k2 v Keq_dec H.
    rev_wlog_induction l as ak av t IH.
    - simpl. rewrite <-distinct.
      reflexivity.
      assumption.
    - wlog_app_simpl.
      destruct (Keq_dec ak k1) as [Hak|Hak].
      + subst. auto.
      + repeat rewrite <-distinct in * by auto.
        auto.
    - wlog_app_simpl.
      destruct (Keq_dec ak k1) as [Hak|Hak].
      + subst. auto.
      + repeat rewrite <-delete_distinct by auto.
        auto.
  Qed.

  Lemma Wlog_ignore_cons_del : forall {K V} (l : @Wlog K V) s k1 k2,
      (forall k1 k2 : K, {k1 = k2} + {k1 <> k2}) ->
      k1 <> k2 ->
      get k1 (Wlog_apply l (delete k2 s)) = get k1 (Wlog_apply l s).
  Proof.
    intros K V l s k1 k2 Keq_dec H.
    rev_wlog_induction l as ak av t IH.
    - simpl. rewrite <-delete_distinct.
      reflexivity.
      assumption.
    - wlog_app_simpl.
      destruct (Keq_dec ak k1) as [Hak|Hak].
      + subst. auto.
      + repeat rewrite <-distinct in * by auto.
        auto.
    - wlog_app_simpl.
      destruct (Keq_dec ak k1) as [Hak|Hak].
      + subst. auto.
      + repeat rewrite <-delete_distinct by auto.
        auto.
  Qed.

  Lemma Wlog_nodup_has_key : forall {K V} k (l1 l2 : @Wlog K V),
                                 Wlog_nodup l1 l2 ->
                                 Wlog_has_key k l1 <-> Wlog_has_key k l2.
  Proof.
    intros K V k l1 l2 H.
    induction H; split; intros Hinv;
      try easy;
      subst; simpl in *;
      unfold Wlog_has_key; simpl;
      unfold Wlog_has_key in Hinv; simpl in Hinv;
      destruct Hinv;
      try (left; assumption);
      apply IHWlog_nodup in H; right; assumption.
  Qed.

  Theorem Wlog_significant_entries :
    forall {K V} (l l' : @Wlog K V) s,
      (forall k1 k2 : K, {k1 = k2} + {k1 <> k2}) ->
      Wlog_nodup l l' ->
      Wlog_apply l s =s= Wlog_apply l' s.
  Proof.
    intros K V l l' s Keq_dec H.
    induction H; subst; auto;
      unfold_s_eq as k';
      unfold_s_eq in IHWlog_nodup;
      apply (Wlog_nodup_has_key k') in H1;
      simpl;
      destruct (Keq_dec k k'); subst;
        (* [k = k'] *)
        try (rewrite <-Wlog_ignore with (l := t) by auto;
             rewrite <-Wlog_ignore with (l := l') by firstorder;
             auto).
        (* [k <> k'] *)
    - repeat rewrite Wlog_ignore_cons with (k2 := k) (v0 := v) by auto.
      auto.
    - repeat rewrite Wlog_ignore_cons_del with (k2 := k) by auto.
      auto.
  Qed.
End WriteLog.

Module Versioned (I : Interface).
  Inductive maybe_dead (A : Type) :=
  | Alive : A -> maybe_dead A
  | Dead : nat -> maybe_dead A.

  Record versioned d := mkVer
                          { version : nat;
                            data : maybe_dead d;
                          }.

  Definition VS K V := I.Storage K (versioned V).

  Definition put {K V} (k : K) (v : V) (s : VS K V) : VS K V :=
    match I.get k s with
    | None => I.put k (mkVer 1 (Alive v)) s
    | Some v0 => I.put k (mkVer (S (version v0)) (Alive v)) s
    end.

  Definition get {K V} (k : K) (s : VS K V) : option V :=
    match I.get k s with
    | None => None
    | Some v => match data v with
               | Alive x => Some x
               | Dead _ _ => None
               end
    end.

  Definition get_v {K V} (k : K) (s : VS K V) : (nat * option V) :=
    match I.get k s with
    | None => (0, None)
    | Some v => match data v with
               | Alive x => (version v, Some x)
               | Dead _ _ => (version v, None)
               end
    end.

  Definition delete {K V} (k : K) (n : nat) (s : VS K V) : VS K V :=
    match I.get k s with
    | None => s
    | Some v0 => I.put k (mkVer (S (version v0)) (Dead V n)) s
    end.

  Definition new {K V} :=
    @I.new K V.
End Versioned.

End Storage.
