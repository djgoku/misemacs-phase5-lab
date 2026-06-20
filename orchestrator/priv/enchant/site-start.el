;;; site-start.el --- misemacs: wire jinx to the bundled enchant -*- lexical-binding: t; -*-

;; Auto-loaded by Emacs at startup (site-run-file = "site-start"). Shipped INSIDE misemacs's
;; Emacs.app (Contents/Resources/site-lisp/) by the relocator so the `jinx' package spell-checks
;; out of the box against the bundled two-provider enchant (hunspell + applespell) — no Homebrew,
;; no pkg-config, no manual setup. The user still installs `jinx' themselves; this only points its
;; first-use compile + runtime at the bundled enchant. Bundle layout (Layout A) is produced by
;; orchestrator/lib/orchestrator/relocate/enchant.ex.

;; arm64 macOS only (v1 scope). Everything is gated on the bundled enchant SDK actually being
;; present, so a non-enchant build (or a non-NS Emacs) is a clean no-op.
(when (eq system-type 'darwin)
  ;; invocation-directory = .../Emacs.app/Contents/MacOS/  ->  Contents = its parent.
  (let* ((contents (expand-file-name ".." invocation-directory))
         (frameworks (expand-file-name "Frameworks" contents))
         (sdk (expand-file-name "Resources/enchant-sdk" contents))
         (sdk-include (expand-file-name "include" sdk))
         (sdk-config (expand-file-name "config" sdk)))
    (when (file-directory-p sdk)
      ;; 1) jinx's first-use `cc' compile of jinx-mod: point at the bundled enchant SDK (no
      ;;    pkg-config) and bake an rpath so the compiled module resolves libenchant from the
      ;;    app's Frameworks at load time (survives app moves / mise upgrades).
      (with-eval-after-load 'jinx
        (setq jinx--compile-flags
              (append (list (concat "-I" sdk-include)
                            (concat "-L" frameworks)
                            "-Wl,-rpath,@executable_path/../Frameworks")
                      jinx--compile-flags)))
      ;; 2) Deliver the hunspell dict + provider ordering via a WRITABLE per-user config dir
      ;;    (enchant writes personal word lists into it), seeded once from the read-only bundle.
      ;;    enchant's hunspell provider reads $ENCHANT_CONFIG_DIR/hunspell/<lang>.{aff,dic} and the
      ;;    provider order from $ENCHANT_CONFIG_DIR/enchant.ordering (applespell first, then hunspell).
      (let ((cfg (expand-file-name "enchant" user-emacs-directory)))
        (when (and (file-directory-p sdk-config)
                   (not (file-exists-p (expand-file-name "enchant.ordering" cfg))))
          (copy-directory sdk-config cfg t t t))
        (setenv "ENCHANT_CONFIG_DIR" cfg)))))

(provide 'site-start)
;;; site-start.el ends here
