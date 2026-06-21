;;; site-start.el --- misemacs: wire jinx to the bundled enchant -*- lexical-binding: t; -*-

;; Auto-loaded by Emacs at startup (site-run-file = "site-start"). Shipped INSIDE misemacs's
;; Emacs.app (Contents/Resources/site-lisp/) by the relocator so the `jinx' package spell-checks
;; out of the box against the bundled two-provider enchant (hunspell + applespell) — no Homebrew,
;; no pkg-config, no manual setup. The user still installs `jinx' themselves; this only points its
;; first-use compile + runtime at the bundled enchant. Bundle layout (Layout A) is produced by
;; orchestrator/lib/orchestrator/relocate/enchant.ex.

;; arm64 macOS only (v1 scope). Everything is gated on the bundled enchant SDK actually being
;; present, so a non-enchant build (or a non-NS Emacs) is a clean no-op.
(defconst misemacs--jinx-enchant-marker "misemacs-jinx-enchant-env/1")

(defun misemacs--c-string-literal (string)
  "Return STRING as a C string literal."
  (concat "\""
          (replace-regexp-in-string "[\\\\\"]" "\\\\\\&" string)
          "\""))

(defun misemacs--file-contains-literal-p (file literal)
  "Return non-nil when FILE contains LITERAL as raw bytes."
  (when (file-readable-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (goto-char (point-min))
      (search-forward literal nil t))))

(defun misemacs--delete-stale-jinx-module (cfg frameworks)
  "Delete a jinx module not compiled for CFG and FRAMEWORKS."
  (when module-file-suffix
    (let ((mod-file (locate-library (concat "jinx-mod" module-file-suffix) t)))
      (when (and mod-file
                 (or (not (misemacs--file-contains-literal-p
                           mod-file misemacs--jinx-enchant-marker))
                     (not (misemacs--file-contains-literal-p mod-file cfg))
                     (not (misemacs--file-contains-literal-p mod-file frameworks))))
        (delete-file mod-file)))))

(defun misemacs--copy-file-if-missing (source dest)
  "Copy SOURCE to DEST when DEST does not already exist."
  (when (and (file-readable-p source)
             (not (file-exists-p dest)))
    (make-directory (file-name-directory dest) t)
    (copy-file source dest nil)))

(defun misemacs--seed-enchant-config (sdk-config cfg)
  "Seed missing files from SDK-CONFIG into writable CFG without overwriting edits."
  (dolist (relative '("enchant.ordering"
                      "AppleSpell.config"
                      "hunspell/en_US.aff"
                      "hunspell/en_US.dic"))
    (misemacs--copy-file-if-missing
     (expand-file-name relative sdk-config)
     (expand-file-name relative cfg))))

(defun misemacs--without-jinx-enchant-flags (flags shim sdk-include frameworks cfg-literal)
  "Return FLAGS without the generated misemacs jinx/enchant flags."
  (let ((remove (list (concat "-I" sdk-include)
                      (concat "-DMISEMACS_ENCHANT_CONFIG_DIR=" cfg-literal)
                      (concat "-L" frameworks)
                      (concat "-Wl,-rpath," frameworks)
                      "-Wl,-rpath,@executable_path/../Frameworks"))
        result)
    (while flags
      (let ((flag (pop flags)))
        (cond
         ((and (equal flag "-include")
               flags
               (equal (car flags) shim))
          (pop flags))
         ((member flag remove))
         (t (push flag result)))))
    (nreverse result)))

(when (eq system-type 'darwin)
  ;; invocation-directory = .../Emacs.app/Contents/MacOS/  ->  Contents = its parent.
  (let* ((contents (expand-file-name ".." invocation-directory))
         (frameworks (expand-file-name "Frameworks" contents))
         (sdk (expand-file-name "Resources/enchant-sdk" contents))
         (sdk-include (expand-file-name "include" sdk))
         (sdk-config (expand-file-name "config" sdk))
         (shim (expand-file-name "misemacs-jinx-enchant-env.h" sdk-include))
         (cfg (expand-file-name "enchant" user-emacs-directory)))
    (when (file-directory-p sdk)
      ;; 1) jinx's first-use `cc' compile of jinx-mod: point at the bundled enchant SDK (no
      ;;    pkg-config), force-include a tiny native env bridge so libenchant sees
      ;;    ENCHANT_CONFIG_DIR from inside jinx-mod.dylib, and bake an rpath so the compiled module
      ;;    resolves libenchant from this app's Frameworks even when that module is shared.
      (with-eval-after-load 'jinx
        (misemacs--delete-stale-jinx-module cfg frameworks)
        (let* ((cfg-literal (misemacs--c-string-literal cfg))
               (misemacs-flags
                (list (concat "-I" sdk-include)
                      "-include" shim
                      (concat "-DMISEMACS_ENCHANT_CONFIG_DIR=" cfg-literal)
                      (concat "-L" frameworks)
                      (concat "-Wl,-rpath," frameworks))))
          (setq jinx--compile-flags
                (append misemacs-flags
                        (misemacs--without-jinx-enchant-flags
                         jinx--compile-flags shim sdk-include frameworks cfg-literal)))))
      ;; 2) Deliver the hunspell dict + provider ordering via a WRITABLE per-user config dir
      ;;    (enchant writes personal word lists into it), seeded from the read-only bundle without
      ;;    overwriting user-edited files.
      ;;    enchant's hunspell provider reads $ENCHANT_CONFIG_DIR/hunspell/<lang>.{aff,dic} and the
      ;;    provider order from $ENCHANT_CONFIG_DIR/enchant.ordering (AppleSpell first, then hunspell).
      (when (file-directory-p sdk-config)
        (misemacs--seed-enchant-config sdk-config cfg))
      ;; Keep Lisp code and subprocesses aligned. Native jinx code gets the same path from
      ;; misemacs-jinx-enchant-env.h, because Emacs Lisp `setenv' alone is not enough there.
      (setenv "ENCHANT_CONFIG_DIR" cfg))))

(provide 'site-start)
;;; site-start.el ends here
