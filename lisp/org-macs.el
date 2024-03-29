;;; org-macs.el --- Top-level Definitions for Org -*- lexical-binding: t; -*-

;; Copyright (C) 2004-2018 Free Software Foundation, Inc.

;; Author: Carsten Dominik <carsten at orgmode dot org>
;; Keywords: outlines, hypermedia, calendar, wp
;; Homepage: https://orgmode.org
;;
;; This file is part of GNU Emacs.
;;
;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:

;; This file contains macro definitions, defsubst definitions, other
;; stuff needed for compilation and top-level forms in Org mode, as
;; well lots of small functions that are not Org mode specific but
;; simply generally useful stuff.

;;; Code:

(require 'format-spec)

(declare-function org-string-collate-lessp "org-compat" (s1 s2 &optional locale ignore-case))

(defvar org-ts-regexp0)


;;; Macros

(defmacro org-with-gensyms (symbols &rest body)
  (declare (debug (sexp body)) (indent 1))
  `(let ,(mapcar (lambda (s)
		   `(,s (make-symbol (concat "--" (symbol-name ',s)))))
                 symbols)
     ,@body))

;; Use `with-silent-modifications' to ignore cosmetic changes and
;; `org-unmodified' to ignore real text modifications.
(defmacro org-unmodified (&rest body)
  "Run BODY while preserving the buffer's `buffer-modified-p' state."
  (declare (debug (body)))
  (org-with-gensyms (was-modified)
    `(let ((,was-modified (buffer-modified-p)))
       (unwind-protect
           (let ((buffer-undo-list t)
		 (inhibit-modification-hooks t))
	     ,@body)
	 (set-buffer-modified-p ,was-modified)))))

(defmacro org-without-partial-completion (&rest body)
  (declare (debug (body)))
  `(if (and (boundp 'partial-completion-mode)
	    partial-completion-mode
	    (fboundp 'partial-completion-mode))
       (unwind-protect
	   (progn
	     (partial-completion-mode -1)
	     ,@body)
	 (partial-completion-mode 1))
     ,@body))

(defmacro org-with-point-at (pom &rest body)
  "Move to buffer and point of point-or-marker POM for the duration of BODY."
  (declare (debug (form body)) (indent 1))
  (org-with-gensyms (mpom)
    `(let ((,mpom ,pom))
       (save-excursion
	 (when (markerp ,mpom) (set-buffer (marker-buffer ,mpom)))
	 (org-with-wide-buffer
	  (goto-char (or ,mpom (point)))
	  ,@body)))))

(defmacro org-with-remote-undo (buffer &rest body)
  "Execute BODY while recording undo information in two buffers."
  (declare (debug (form body)) (indent 1))
  (org-with-gensyms (cline cmd buf1 buf2 undo1 undo2 c1 c2)
    `(let ((,cline (org-current-line))
	   (,cmd this-command)
	   (,buf1 (current-buffer))
	   (,buf2 ,buffer)
	   (,undo1 buffer-undo-list)
	   (,undo2 (with-current-buffer ,buffer buffer-undo-list))
	   ,c1 ,c2)
       ,@body
       (when org-agenda-allow-remote-undo
	 (setq ,c1 (org-verify-change-for-undo
		    ,undo1 (with-current-buffer ,buf1 buffer-undo-list))
	       ,c2 (org-verify-change-for-undo
		    ,undo2 (with-current-buffer ,buf2 buffer-undo-list)))
	 (when (or ,c1 ,c2)
	   ;; make sure there are undo boundaries
	   (and ,c1 (with-current-buffer ,buf1 (undo-boundary)))
	   (and ,c2 (with-current-buffer ,buf2 (undo-boundary)))
	   ;; remember which buffer to undo
	   (push (list ,cmd ,cline ,buf1 ,c1 ,buf2 ,c2)
		 org-agenda-undo-list))))))

(defmacro org-no-read-only (&rest body)
  "Inhibit read-only for BODY."
  (declare (debug (body)))
  `(let ((inhibit-read-only t)) ,@body))

(defmacro org-save-outline-visibility (use-markers &rest body)
  "Save and restore outline visibility around BODY.
If USE-MARKERS is non-nil, use markers for the positions.  This
means that the buffer may change while running BODY, but it also
means that the buffer should stay alive during the operation,
because otherwise all these markers will point to nowhere."
  (declare (debug (form body)) (indent 1))
  (org-with-gensyms (data invisible-types markers?)
    `(let* ((,invisible-types '(org-hide-block org-hide-drawer outline))
	    (,markers? ,use-markers)
	    (,data
	     (mapcar (lambda (o)
		       (let ((beg (overlay-start o))
			     (end (overlay-end o))
			     (type (overlay-get o 'invisible)))
			 (and beg end
			      (> end beg)
			      (memq type ,invisible-types)
			      (list (if ,markers? (copy-marker beg) beg)
				    (if ,markers? (copy-marker end t) end)
				    type))))
		     (org-with-wide-buffer
		      (overlays-in (point-min) (point-max))))))
       (unwind-protect (progn ,@body)
	 (org-with-wide-buffer
	  (dolist (type ,invisible-types)
	    (remove-overlays (point-min) (point-max) 'invisible type))
	  (pcase-dolist (`(,beg ,end ,type) (delq nil ,data))
	    (org-flag-region beg end t type)
	    (when ,markers?
	      (set-marker beg nil)
	      (set-marker end nil))))))))

(defmacro org-with-wide-buffer (&rest body)
  "Execute body while temporarily widening the buffer."
  (declare (debug (body)))
  `(save-excursion
     (save-restriction
       (widen)
       ,@body)))

(defmacro org-with-limited-levels (&rest body)
  "Execute BODY with limited number of outline levels."
  (declare (debug (body)))
  `(progn
     (defvar org-called-with-limited-levels)
     (defvar org-outline-regexp)
     (defvar outline-regexp)
     (defvar org-outline-regexp-bol)
     (let* ((org-called-with-limited-levels t)
            (org-outline-regexp (org-get-limited-outline-regexp))
            (outline-regexp org-outline-regexp)
            (org-outline-regexp-bol (concat "^" org-outline-regexp)))
       ,@body)))

(defmacro org-eval-in-environment (environment form)
  (declare (debug (form form)) (indent 1))
  `(eval (list 'let ,environment ',form)))

;;;###autoload
(defmacro org-load-noerror-mustsuffix (file)
  "Load FILE with optional arguments NOERROR and MUSTSUFFIX."
  `(load ,file 'noerror nil nil 'mustsuffix))

(defmacro org-preserve-local-variables (&rest body)
  "Execute BODY while preserving local variables."
  (declare (debug (body)))
  `(let ((local-variables
	  (org-with-wide-buffer
	   (goto-char (point-max))
	   (let ((case-fold-search t))
	     (and (re-search-backward "^[ \t]*# +Local Variables:"
				      (max (- (point) 3000) 1)
				      t)
		  (delete-and-extract-region (point) (point-max)))))))
     (unwind-protect (progn ,@body)
       (when local-variables
	 (org-with-wide-buffer
	  (goto-char (point-max))
	  (unless (bolp) (insert "\n"))
	  (insert local-variables))))))

(defmacro org-no-popups (&rest body)
  "Suppress popup windows and evaluate BODY."
  `(let (pop-up-frames display-buffer-alist)
     ,@body))



;;; Buffer and windows

(defun org-base-buffer (buffer)
  "Return the base buffer of BUFFER, if it has one.  Else return the buffer."
  (when buffer
    (or (buffer-base-buffer buffer)
	buffer)))

(defun org-find-base-buffer-visiting (file)
  "Like `find-buffer-visiting' but always return the base buffer and
not an indirect buffer."
  (let ((buf (or (get-file-buffer file)
		 (find-buffer-visiting file))))
    (org-base-buffer buf)))

(defun org-switch-to-buffer-other-window (&rest args)
  "Switch to buffer in a second window on the current frame.
In particular, do not allow pop-up frames.
Returns the newly created buffer."
  (org-no-popups (apply #'switch-to-buffer-other-window args)))

(defun org-fit-window-to-buffer (&optional window max-height min-height
                                           shrink-only)
  "Fit WINDOW to the buffer, but only if it is not a side-by-side window.
WINDOW defaults to the selected window.  MAX-HEIGHT and MIN-HEIGHT are
passed through to `fit-window-to-buffer'.  If SHRINK-ONLY is set, call
`shrink-window-if-larger-than-buffer' instead, the height limit is
ignored in this case."
  (cond ((if (fboundp 'window-full-width-p)
             (not (window-full-width-p window))
           ;; Do nothing if another window would suffer.
           (> (frame-width) (window-width window))))
        ((and (fboundp 'fit-window-to-buffer) (not shrink-only))
         (fit-window-to-buffer window max-height min-height))
        ((fboundp 'shrink-window-if-larger-than-buffer)
         (shrink-window-if-larger-than-buffer window)))
  (or window (selected-window)))



;;; File

(defun org-file-newer-than-p (file time)
  "Non-nil if FILE is newer than TIME.
FILE is a filename, as a string, TIME is a list of integers, as
returned by, e.g., `current-time'."
  (and (file-exists-p file)
       ;; Only compare times up to whole seconds as some file-systems
       ;; (e.g. HFS+) do not retain any finer granularity.  As
       ;; a consequence, make sure we return non-nil when the two
       ;; times are equal.
       (not (time-less-p (cl-subseq (nth 5 (file-attributes file)) 0 2)
			 (cl-subseq time 0 2)))))

(defun org-compile-file (source process ext &optional err-msg log-buf spec)
  "Compile a SOURCE file using PROCESS.

PROCESS is either a function or a list of shell commands, as
strings.  EXT is a file extension, without the leading dot, as
a string.  It is used to check if the process actually succeeded.

PROCESS must create a file with the same base name and directory
as SOURCE, but ending with EXT.  The function then returns its
filename.  Otherwise, it raises an error.  The error message can
then be refined by providing string ERR-MSG, which is appended to
the standard message.

If PROCESS is a function, it is called with a single argument:
the SOURCE file.

If it is a list of commands, each of them is called using
`shell-command'.  By default, in each command, %b, %f, %F, %o and
%O are replaced with, respectively, SOURCE base name, name, full
name, directory and absolute output file name.  It is possible,
however, to use more place-holders by specifying them in optional
argument SPEC, as an alist following the pattern

  (CHARACTER . REPLACEMENT-STRING).

When PROCESS is a list of commands, optional argument LOG-BUF can
be set to a buffer or a buffer name.  `shell-command' then uses
it for output."
  (let* ((base-name (file-name-base source))
	 (full-name (file-truename source))
	 (out-dir (or (file-name-directory source) "./"))
	 (output (expand-file-name (concat base-name "." ext) out-dir))
	 (time (current-time))
	 (err-msg (if (stringp err-msg) (concat ".  " err-msg) "")))
    (save-window-excursion
      (pcase process
	((pred functionp) (funcall process (shell-quote-argument source)))
	((pred consp)
	 (let ((log-buf (and log-buf (get-buffer-create log-buf)))
	       (spec (append spec
			     `((?b . ,(shell-quote-argument base-name))
			       (?f . ,(shell-quote-argument source))
			       (?F . ,(shell-quote-argument full-name))
			       (?o . ,(shell-quote-argument out-dir))
			       (?O . ,(shell-quote-argument output))))))
	   (dolist (command process)
	     (shell-command (format-spec command spec) log-buf))
	   (when log-buf (with-current-buffer log-buf (compilation-mode)))))
	(_ (error "No valid command to process %S%s" source err-msg))))
    ;; Check for process failure.  Output file is expected to be
    ;; located in the same directory as SOURCE.
    (unless (org-file-newer-than-p output time)
      (error (format "File %S wasn't produced%s" output err-msg)))
    output))



;;; Indentation

(defun org-do-remove-indentation (&optional n)
  "Remove the maximum common indentation from the buffer.
When optional argument N is a positive integer, remove exactly
that much characters from indentation, if possible.  Return nil
if it fails."
  (catch :exit
    (goto-char (point-min))
    ;; Find maximum common indentation, if not specified.
    (let ((n (or n
		 (let ((min-ind (point-max)))
		   (save-excursion
		     (while (re-search-forward "^[ \t]*\\S-" nil t)
		       (let ((ind (1- (current-column))))
			 (if (zerop ind) (throw :exit nil)
			   (setq min-ind (min min-ind ind))))))
		   min-ind))))
      (if (zerop n) (throw :exit nil)
	;; Remove exactly N indentation, but give up if not possible.
	(while (not (eobp))
	  (let ((ind (progn (skip-chars-forward " \t") (current-column))))
	    (cond ((eolp) (delete-region (line-beginning-position) (point)))
		  ((< ind n) (throw :exit nil))
		  (t (indent-line-to (- ind n))))
	    (forward-line)))
	;; Signal success.
	t))))



;;; Input

(defun org-read-function (prompt &optional allow-empty?)
  "Prompt for a function.
If ALLOW-EMPTY? is non-nil, return nil rather than raising an
error when the user input is empty."
  (let ((func (completing-read prompt obarray #'fboundp t)))
    (cond ((not (string= func ""))
	   (intern func))
	  (allow-empty? nil)
	  (t (user-error "Empty input is not valid")))))

(defun org-completing-read (&rest args)
  "Completing-read with SPACE being a normal character."
  (let ((enable-recursive-minibuffers t)
	(minibuffer-local-completion-map
	 (copy-keymap minibuffer-local-completion-map)))
    (define-key minibuffer-local-completion-map " " 'self-insert-command)
    (define-key minibuffer-local-completion-map "?" 'self-insert-command)
    (define-key minibuffer-local-completion-map (kbd "C-c !")
      'org-time-stamp-inactive)
    (apply #'completing-read args)))

(defun org--mks-read-key (allowed-keys prompt)
  "Read a key and ensure it is a member of ALLOWED-KEYS.
TAB, SPC and RET are treated equivalently."
  (let* ((key (char-to-string
	       (pcase (read-char-exclusive prompt)
		 ((or ?\s ?\t ?\r) ?\t)
		 (char char)))))
    (if (member key allowed-keys)
        key
      (message "Invalid key: `%s'" key)
      (sit-for 1)
      (org--mks-read-key allowed-keys prompt))))

(defun org-mks (table title &optional prompt specials)
  "Select a member of an alist with multiple keys.

TABLE is the alist which should contain entries where the car is a string.
There should be two types of entries.

1. prefix descriptions like (\"a\" \"Description\")
   This indicates that `a' is a prefix key for multi-letter selection, and
   that there are entries following with keys like \"ab\", \"ax\"...

2. Select-able members must have more than two elements, with the first
   being the string of keys that lead to selecting it, and the second a
   short description string of the item.

The command will then make a temporary buffer listing all entries
that can be selected with a single key, and all the single key
prefixes.  When you press the key for a single-letter entry, it is selected.
When you press a prefix key, the commands (and maybe further prefixes)
under this key will be shown and offered for selection.

TITLE will be placed over the selection in the temporary buffer,
PROMPT will be used when prompting for a key.  SPECIALS is an
alist with (\"key\" \"description\") entries.  When one of these
is selected, only the bare key is returned."
  (save-window-excursion
    (let ((inhibit-quit t)
	  (buffer (org-switch-to-buffer-other-window "*Org Select*"))
	  (prompt (or prompt "Select: "))
	  current)
      (unwind-protect
	  (catch 'exit
	    (while t
	      (erase-buffer)
	      (insert title "\n\n")
	      (let ((des-keys nil)
		    (allowed-keys '("\C-g"))
		    (tab-alternatives '("\s" "\t" "\r"))
		    (cursor-type nil))
		;; Populate allowed keys and descriptions keys
		;; available with CURRENT selector.
		(let ((re (format "\\`%s\\(.\\)\\'"
				  (if current (regexp-quote current) "")))
		      (prefix (if current (concat current " ") "")))
		  (dolist (entry table)
		    (pcase entry
		      ;; Description.
		      (`(,(and key (pred (string-match re))) ,desc)
		       (let ((k (match-string 1 key)))
			 (push k des-keys)
			 ;; Keys ending in tab, space or RET are equivalent.
			 (if (member k tab-alternatives)
			     (push "\t" allowed-keys)
			   (push k allowed-keys))
			 (insert prefix "[" k "]" "..." "  " desc "..." "\n")))
		      ;; Usable entry.
		      (`(,(and key (pred (string-match re))) ,desc . ,_)
		       (let ((k (match-string 1 key)))
			 (insert prefix "[" k "]" "     " desc "\n")
			 (push k allowed-keys)))
		      (_ nil))))
		;; Insert special entries, if any.
		(when specials
		  (insert "----------------------------------------------------\
---------------------------\n")
		  (pcase-dolist (`(,key ,description) specials)
		    (insert (format "[%s]     %s\n" key description))
		    (push key allowed-keys)))
		;; Display UI and let user select an entry or
		;; a sub-level prefix.
		(goto-char (point-min))
		(unless (pos-visible-in-window-p (point-max))
		  (org-fit-window-to-buffer))
		(let ((pressed (org--mks-read-key allowed-keys prompt)))
		  (setq current (concat current pressed))
		  (cond
		   ((equal pressed "\C-g") (user-error "Abort"))
		   ;; Selection is a prefix: open a new menu.
		   ((member pressed des-keys))
		   ;; Selection matches an association: return it.
		   ((let ((entry (assoc current table)))
		      (and entry (throw 'exit entry))))
		   ;; Selection matches a special entry: return the
		   ;; selection prefix.
		   ((assoc current specials) (throw 'exit current))
		   (t (error "No entry available")))))))
	(when buffer (kill-buffer buffer))))))


;;; List manipulation

(defsubst org-get-alist-option (option key)
  (cond ((eq key t) t)
	((eq option t) t)
	((assoc key option) (cdr (assoc key option)))
	(t (let ((r (cdr (assq 'default option))))
	     (if (listp r) (delq nil r) r)))))

(defsubst org-last (list)
  "Return the last element of LIST."
  (car (last list)))

(defsubst org-uniquify (list)
  "Non-destructively remove duplicate elements from LIST."
  (let ((res (copy-sequence list))) (delete-dups res)))

(defun org-uniquify-alist (alist)
  "Merge elements of ALIST with the same key.

For example, in this alist:

\(org-uniquify-alist \\='((a 1) (b 2) (a 3)))
  => \\='((a 1 3) (b 2))

merge (a 1) and (a 3) into (a 1 3).

The function returns the new ALIST."
  (let (rtn)
    (dolist (e alist rtn)
      (let (n)
	(if (not (assoc (car e) rtn))
	    (push e rtn)
	  (setq n (cons (car e) (append (cdr (assoc (car e) rtn)) (cdr e))))
	  (setq rtn (assq-delete-all (car e) rtn))
	  (push n rtn))))))

(defun org-delete-all (elts list)
  "Remove all elements in ELTS from LIST.
Comparison is done with `equal'.  It is a destructive operation
that may remove elements by altering the list structure."
  (while elts
    (setq list (delete (pop elts) list)))
  list)

(defun org-plist-delete (plist property)
  "Delete PROPERTY from PLIST.
This is in contrast to merely setting it to 0."
  (let (p)
    (while plist
      (if (not (eq property (car plist)))
	  (setq p (plist-put p (car plist) (nth 1 plist))))
      (setq plist (cddr plist)))
    p))

(defun org-combine-plists (&rest plists)
  "Create a single property list from all plists in PLISTS.
The process starts by copying the first list, and then setting properties
from the other lists.  Settings in the last list are the most significant
ones and overrule settings in the other lists."
  (let ((rtn (copy-sequence (pop plists)))
	p v ls)
    (while plists
      (setq ls (pop plists))
      (while ls
	(setq p (pop ls) v (pop ls))
	(setq rtn (plist-put rtn p v))))
    rtn))



;;; Local variables

(defconst org-unique-local-variables
  '(org-element--cache
    org-element--cache-objects
    org-element--cache-sync-keys
    org-element--cache-sync-requests
    org-element--cache-sync-timer)
  "List of local variables that cannot be transferred to another buffer.")

(defun org-get-local-variables ()
  "Return a list of all local variables in an Org mode buffer."
  (delq nil
	(mapcar
	 (lambda (x)
	   (let* ((binding (if (symbolp x) (list x) (list (car x) (cdr x))))
		  (name (car binding)))
	     (and (not (get name 'org-state))
		  (not (memq name org-unique-local-variables))
		  (string-match-p
		   "\\`\\(org-\\|orgtbl-\\|outline-\\|comment-\\|paragraph-\\|\
auto-fill\\|normal-auto-fill\\|fill-paragraph\\|indent-\\)"
		   (symbol-name name))
		  binding)))
	 (with-temp-buffer
	   (org-mode)
	   (buffer-local-variables)))))

(defun org-clone-local-variables (from-buffer &optional regexp)
  "Clone local variables from FROM-BUFFER.
Optional argument REGEXP selects variables to clone."
  (dolist (pair (buffer-local-variables from-buffer))
    (pcase pair
      (`(,name . ,value)		;ignore unbound variables
       (when (and (not (memq name org-unique-local-variables))
		  (or (null regexp) (string-match-p regexp (symbol-name name))))
	 (ignore-errors (set (make-local-variable name) value)))))))



;;; Logic

(defsubst org-xor (a b)
  "Exclusive `or'."
  (if a (not b) b))



;;; Miscellaneous

(defsubst org-call-with-arg (command arg)
  "Call COMMAND interactively, but pretend prefix arg was ARG."
  (let ((current-prefix-arg arg)) (call-interactively command)))

(defsubst org-check-external-command (cmd &optional use no-error)
  "Check if external program CMD for USE exists, error if not.
When the program does exist, return its path.
When it does not exist and NO-ERROR is set, return nil.
Otherwise, throw an error.  The optional argument USE can describe what this
program is needed for, so that the error message can be more informative."
  (or (executable-find cmd)
      (if no-error
	  nil
	(error "Can't find `%s'%s" cmd
	       (if use (format " (%s)" use) "")))))

(defun org-display-warning (message)
  "Display the given MESSAGE as a warning."
  (display-warning 'org message :warning))

(defun org-unlogged-message (&rest args)
  "Display a message, but avoid logging it in the *Messages* buffer."
  (let ((message-log-max nil))
    (apply #'message args)))

(defun org-let (list &rest body)
  (eval (cons 'let (cons list body))))
(put 'org-let 'lisp-indent-function 1)

(defun org-let2 (list1 list2 &rest body)
  (eval (cons 'let (cons list1 (list (cons 'let (cons list2 body)))))))
(put 'org-let2 'lisp-indent-function 2)

(defun org-eval (form)
  "Eval FORM and return result."
  (condition-case error
      (eval form)
    (error (format "%%![Error: %s]" error))))

(defvar org-outline-regexp) ; defined in org.el
(defvar org-odd-levels-only) ; defined in org.el
(defvar org-inlinetask-min-level) ; defined in org-inlinetask.el
(defun org-get-limited-outline-regexp ()
  "Return outline-regexp with limited number of levels.
The number of levels is controlled by `org-inlinetask-min-level'"
  (cond ((not (derived-mode-p 'org-mode))
	 outline-regexp)
	((not (featurep 'org-inlinetask))
	 org-outline-regexp)
	(t
	 (let* ((limit-level (1- org-inlinetask-min-level))
		(nstars (if org-odd-levels-only
			    (1- (* limit-level 2))
			  limit-level)))
	   (format "\\*\\{1,%d\\} " nstars)))))



;;; Motion

(defsubst org-goto-line (N)
  (save-restriction
    (widen)
    (goto-char (point-min))
    (forward-line (1- N))))

(defsubst org-current-line (&optional pos)
  (save-excursion
    (and pos (goto-char pos))
    ;; works also in narrowed buffer, because we start at 1, not point-min
    (+ (if (bolp) 1 0) (count-lines 1 (point)))))



;;; Overlays

(defun org-overlay-display (ovl text &optional face evap)
  "Make overlay OVL display TEXT with face FACE."
  (overlay-put ovl 'display text)
  (when face (overlay-put ovl 'face face))
  (when evap (overlay-put ovl 'evaporate t)))

(defun org-overlay-before-string (ovl text &optional face evap)
  "Make overlay OVL display TEXT with face FACE."
  (when face (org-add-props text nil 'face face))
  (overlay-put ovl 'before-string text)
  (when evap (overlay-put ovl 'evaporate t)))

(defun org-find-overlays (prop &optional pos delete)
  "Find all overlays specifying PROP at POS or point.
If DELETE is non-nil, delete all those overlays."
  (let (found)
    (dolist (ov (overlays-at (or pos (point))) found)
      (cond ((not (overlay-get ov prop)))
	    (delete (delete-overlay ov))
	    (t (push ov found))))))

(defun org-flag-region (from to flag spec)
  "Hide or show lines from FROM to TO, according to FLAG.
SPEC is the invisibility spec, as a symbol."
  (remove-overlays from to 'invisible spec)
  ;; Use `front-advance' since text right before to the beginning of
  ;; the overlay belongs to the visible line than to the contents.
  (when flag
    (let ((o (make-overlay from to nil 'front-advance)))
      (overlay-put o 'evaporate t)
      (overlay-put o 'invisible spec)
      (overlay-put o 'isearch-open-invisible #'delete-overlay))))



;;; Regexp matching

(defsubst org-pos-in-match-range (pos n)
  (and (match-beginning n)
       (<= (match-beginning n) pos)
       (>= (match-end n) pos)))

(defun org-skip-whitespace ()
  "Skip over space, tabs and newline characters."
  (skip-chars-forward " \t\n\r"))

(defun org-match-line (regexp)
  "Match REGEXP at the beginning of the current line."
  (save-excursion
    (beginning-of-line)
    (looking-at regexp)))

(defun org-match-any-p (re list)
  "Non-nil if regexp RE matches an element in LIST."
  (cl-some (lambda (x) (string-match-p re x)) list))

(defun org-in-regexp (regexp &optional nlines visually)
  "Check if point is inside a match of REGEXP.

Normally only the current line is checked, but you can include
NLINES extra lines around point into the search.  If VISUALLY is
set, require that the cursor is not after the match but really
on, so that the block visually is on the match.

Return nil or a cons cell (BEG . END) where BEG and END are,
respectively, the positions at the beginning and the end of the
match."
  (catch :exit
    (let ((pos (point))
          (eol (line-end-position (if nlines (1+ nlines) 1))))
      (save-excursion
	(beginning-of-line (- 1 (or nlines 0)))
	(while (and (re-search-forward regexp eol t)
		    (<= (match-beginning 0) pos))
	  (let ((end (match-end 0)))
	    (when (or (> end pos) (and (= end pos) (not visually)))
	      (throw :exit (cons (match-beginning 0) (match-end 0))))))))))

(defun org-point-in-group (point group &optional context)
  "Check if POINT is in match-group GROUP.
If CONTEXT is non-nil, return a list with CONTEXT and the boundaries of the
match.  If the match group does not exist or point is not inside it,
return nil."
  (and (match-beginning group)
       (>= point (match-beginning group))
       (<= point (match-end group))
       (if context
	   (list context (match-beginning group) (match-end group))
	 t)))



;;; String manipulation

(defun org-string< (a b)
  (org-string-collate-lessp a b))

(defun org-string<= (a b)
  (or (string= a b) (org-string-collate-lessp a b)))

(defun org-string>= (a b)
  (not (org-string-collate-lessp a b)))

(defun org-string> (a b)
  (and (not (string= a b))
       (not (org-string-collate-lessp a b))))

(defun org-string<> (a b)
  (not (string= a b)))

(defsubst org-trim (s &optional keep-lead)
  "Remove whitespace at the beginning and the end of string S.
When optional argument KEEP-LEAD is non-nil, removing blank lines
at the beginning of the string does not affect leading indentation."
  (replace-regexp-in-string
   (if keep-lead "\\`\\([ \t]*\n\\)+" "\\`[ \t\n\r]+") ""
   (replace-regexp-in-string "[ \t\n\r]+\\'" "" s)))

(defun org-string-nw-p (s)
  "Return S if S is a string containing a non-blank character.
Otherwise, return nil."
  (and (stringp s)
       (string-match-p "[^ \r\t\n]" s)
       s))

(defun org-reverse-string (string)
  "Return the reverse of STRING."
  (apply #'string (nreverse (string-to-list string))))

(defun org-split-string (string &optional separators)
  "Splits STRING into substrings at SEPARATORS.

SEPARATORS is a regular expression.  When nil, it defaults to
\"[ \f\t\n\r\v]+\".

Unlike `split-string', matching SEPARATORS at the beginning and
end of string are ignored."
  (let ((separators (or separators "[ \f\t\n\r\v]+")))
    (when (string-match (concat "\\`" separators) string)
      (setq string (replace-match "" nil nil string)))
    (when (string-match (concat separators "\\'") string)
      (setq string (replace-match "" nil nil string)))
    (split-string string separators)))

(defun org-string-display (string)
  "Return STRING as it is displayed in the current buffer.
This function takes into consideration `invisible' and `display'
text properties."
  (let* ((build-from-parts
	  (lambda (s property filter)
	    ;; Build a new string out of string S.  On every group of
	    ;; contiguous characters with the same PROPERTY value,
	    ;; call FILTER on the properties list at the beginning of
	    ;; the group.  If it returns a string, replace the
	    ;; characters in the group with it.  Otherwise, preserve
	    ;; those characters.
	    (let ((len (length s))
		  (new "")
		  (i 0)
		  (cursor 0))
	      (while (setq i (text-property-not-all i len property nil s))
		(let ((end (next-single-property-change i property s len))
		      (value (funcall filter (text-properties-at i s))))
		  (when value
		    (setq new (concat new (substring s cursor i) value))
		    (setq cursor end))
		  (setq i end)))
	      (concat new (substring s cursor)))))
	 (prune-invisible
	  (lambda (s)
	    (funcall build-from-parts s 'invisible
		     (lambda (props)
		       ;; If `invisible' property in PROPS means text
		       ;; is to be invisible, return the empty string.
		       ;; Otherwise return nil so that the part is
		       ;; skipped.
		       (and (or (eq t buffer-invisibility-spec)
				(assoc-string (plist-get props 'invisible)
					      buffer-invisibility-spec))
			    "")))))
	 (replace-display
	  (lambda (s)
	    (funcall build-from-parts s 'display
		     (lambda (props)
		       ;; If there is any string specification in
		       ;; `display' property return it.  Also attach
		       ;; other text properties on the part to that
		       ;; string (face...).
		       (let* ((display (plist-get props 'display))
			      (value (if (stringp display) display
				       (cl-some #'stringp display))))
			 (when value
			   (apply #'propertize
				  ;; Displayed string could contain
				  ;; invisible parts, but no nested
				  ;; display.
				  (funcall prune-invisible value)
				  'display
				  (and (not (stringp display))
				       (cl-remove-if #'stringp display))
				  props))))))))
    ;; `display' property overrides `invisible' one.  So we first
    ;; replace characters with `display' property.  Then we remove
    ;; invisible characters.
    (funcall prune-invisible (funcall replace-display string))))

(defun org-string-width (string)
  "Return width of STRING when displayed in the current buffer.
Unlike `string-width', this function takes into consideration
`invisible' and `display' text properties."
  (string-width (org-string-display string)))

(defun org-not-nil (v)
  "If V not nil, and also not the string \"nil\", then return V.
Otherwise return nil."
  (and v (not (equal v "nil")) v))

(defun org-unbracket-string (pre post string)
  "Remove PRE/POST from the beginning/end of STRING.
Both PRE and POST must be pre-/suffixes of STRING, or neither is
removed."
  (if (and (string-prefix-p pre string)
	   (string-suffix-p post string))
      (substring string (length pre) (- (length post)))
    string))

(defsubst org-current-line-string (&optional to-here)
  (buffer-substring (point-at-bol) (if to-here (point) (point-at-eol))))

(defun org-shorten-string (s maxlength)
  "Shorten string S so that it is no longer than MAXLENGTH characters.
If the string is shorter or has length MAXLENGTH, just return the
original string.  If it is longer, the functions finds a space in the
string, breaks this string off at that locations and adds three dots
as ellipsis.  Including the ellipsis, the string will not be longer
than MAXLENGTH.  If finding a good breaking point in the string does
not work, the string is just chopped off in the middle of a word
if necessary."
  (if (<= (length s) maxlength)
      s
    (let* ((n (max (- maxlength 4) 1))
	   (re (concat "\\`\\(.\\{1," (int-to-string n) "\\}[^ ]\\)\\([ ]\\|\\'\\)")))
      (if (string-match re s)
	  (concat (match-string 1 s) "...")
	(concat (substring s 0 (max (- maxlength 3) 0)) "...")))))

(defun org-remove-tabs (s &optional width)
  "Replace tabulators in S with spaces.
Assumes that s is a single line, starting in column 0."
  (setq width (or width tab-width))
  (while (string-match "\t" s)
    (setq s (replace-match
	     (make-string
	      (- (* width (/ (+ (match-beginning 0) width) width))
		 (match-beginning 0)) ?\ )
	     t t s)))
  s)

(defun org-wrap (string &optional width lines)
  "Wrap string to either a number of lines, or a width in characters.
If WIDTH is non-nil, the string is wrapped to that width, however many lines
that costs.  If there is a word longer than WIDTH, the text is actually
wrapped to the length of that word.
IF WIDTH is nil and LINES is non-nil, the string is forced into at most that
many lines, whatever width that takes.
The return value is a list of lines, without newlines at the end."
  (let* ((words (split-string string))
	 (maxword (apply 'max (mapcar 'org-string-width words)))
	 w ll)
    (cond (width
	   (org--do-wrap words (max maxword width)))
	  (lines
	   (setq w maxword)
	   (setq ll (org--do-wrap words maxword))
	   (if (<= (length ll) lines)
	       ll
	     (setq ll words)
	     (while (> (length ll) lines)
	       (setq w (1+ w))
	       (setq ll (org--do-wrap words w)))
	     ll))
	  (t (error "Cannot wrap this")))))

(defun org--do-wrap (words width)
  "Create lines of maximum width WIDTH (in characters) from word list WORDS."
  (let (lines line)
    (while words
      (setq line (pop words))
      (while (and words (< (+ (length line) (length (car words))) width))
	(setq line (concat line " " (pop words))))
      (setq lines (push line lines)))
    (nreverse lines)))

(defun org-remove-indentation (code &optional n)
  "Remove maximum common indentation in string CODE and return it.
N may optionally be the number of columns to remove.  Return CODE
as-is if removal failed."
  (with-temp-buffer
    (insert code)
    (if (org-do-remove-indentation n) (buffer-string) code)))



;;; Text properties

(defconst org-rm-props '(invisible t face t keymap t intangible t mouse-face t
				   rear-nonsticky t mouse-map t fontified t
				   org-emphasis t)
  "Properties to remove when a string without properties is wanted.")

(defsubst org-no-properties (s &optional restricted)
  "Remove all text properties from string S.
When RESTRICTED is non-nil, only remove the properties listed
in `org-rm-props'."
  (if restricted (remove-text-properties 0 (length s) org-rm-props s)
    (set-text-properties 0 (length s) nil s))
  s)
(defun org-add-props (string plist &rest props)
  "Add text properties to entire string, from beginning to end.
PLIST may be a list of properties, PROPS are individual properties and values
that will be added to PLIST.  Returns the string that was modified."
  (declare (indent 2))
  (add-text-properties
   0 (length string) (if props (append plist props) plist) string)
  string)

(defun org-make-parameter-alist (flat)
  "Return alist based on FLAT.
FLAT is a list with alternating symbol names and values.  The
returned alist is a list of lists with the symbol name in car and
the value in cdr."
  (when flat
    (cons (list (car flat) (cadr flat))
	  (org-make-parameter-alist (cddr flat)))))

(defsubst org-get-at-bol (property)
  "Get text property PROPERTY at the beginning of line."
  (get-text-property (point-at-bol) property))

(defun org-get-at-eol (property n)
  "Get text property PROPERTY at the end of line less N characters."
  (get-text-property (- (point-at-eol) n) property))

(defun org-find-text-property-in-string (prop s)
  "Return the first non-nil value of property PROP in string S."
  (or (get-text-property 0 prop s)
      (get-text-property (or (next-single-property-change 0 prop s) 0)
			 prop s)))

(defun org-invisible-p (&optional pos)
  "Non-nil if the character after POS is invisible.
If POS is nil, use `point' instead."
  (get-char-property (or pos (point)) 'invisible))

(defun org-truely-invisible-p ()
  "Check if point is at a character currently not visible.
This version does not only check the character property, but also
`visible-mode'."
  (unless (bound-and-true-p visible-mode)
    (org-invisible-p)))

(defun org-invisible-p2 ()
  "Check if point is at a character currently not visible.
If the point is at EOL (and not at the beginning of a buffer too),
move it back by one char before doing this check."
  (save-excursion
    (when (and (eolp) (not (bobp)))
      (backward-char 1))
    (org-invisible-p)))


;;; Tables

;; This macro is placed here because it is used in org.el.
;; org-table.el requires org.el.  So, if we put this macro in its
;; natural place (org-table), a require loop would result.
(defmacro org-table-with-shrunk-field (&rest body)
  "Save field shrunk state, execute BODY and restore state."
  (declare (debug (body)))
  (org-with-gensyms (end shrunk size)
    `(let* ((,shrunk (save-match-data (org-table--shrunk-field)))
	    (,end (and ,shrunk (copy-marker (overlay-end ,shrunk) t)))
	    (,size (and ,shrunk (- ,end (overlay-start ,shrunk)))))
       (when ,shrunk (delete-overlay ,shrunk))
       (unwind-protect (progn ,@body)
	 (when ,shrunk (move-overlay ,shrunk (- ,end ,size) ,end))))))


;;; Time

(defun org-2ft (s)
  "Convert S to a floating point time.
If S is already a number, just return it.  If it is a string,
parse it as a time string and apply `float-time' to it.  If S is
nil, just return 0."
  (cond
   ((numberp s) s)
   ((stringp s)
    (condition-case nil
	(float-time (apply #'encode-time (org-parse-time-string s)))
      (error 0.)))
   (t 0.)))

(defun org-time= (a b)
  (let ((a (org-2ft a))
	(b (org-2ft b)))
    (and (> a 0) (> b 0) (= a b))))

(defun org-time< (a b)
  (let ((a (org-2ft a))
	(b (org-2ft b)))
    (and (> a 0) (> b 0) (< a b))))

(defun org-time<= (a b)
  (let ((a (org-2ft a))
	(b (org-2ft b)))
    (and (> a 0) (> b 0) (<= a b))))

(defun org-time> (a b)
  (let ((a (org-2ft a))
	(b (org-2ft b)))
    (and (> a 0) (> b 0) (> a b))))

(defun org-time>= (a b)
  (let ((a (org-2ft a))
	(b (org-2ft b)))
    (and (> a 0) (> b 0) (>= a b))))

(defun org-time<> (a b)
  (let ((a (org-2ft a))
	(b (org-2ft b)))
    (and (> a 0) (> b 0) (\= a b))))

(defun org-parse-time-string (s &optional nodefault)
  "Parse Org time string S.

If time is not given, defaults to 0:00.  However, with optional
NODEFAULT, hour and minute fields are nil if not given.

Throw an error if S in not a valid Org time string.

This should be a lot faster than the `parse-time-string'."
  (unless (string-match org-ts-regexp0 s)
    (error "Not an Org time string: %s" s))
  (list 0
	(cond ((match-beginning 8) (string-to-number (match-string 8 s)))
	      (nodefault nil)
	      (t 0))
	(cond ((match-beginning 7) (string-to-number (match-string 7 s)))
	      (nodefault nil)
	      (t 0))
	(string-to-number (match-string 4 s))
	(string-to-number (match-string 3 s))
	(string-to-number (match-string 2 s))
	nil nil nil))

(defun org-matcher-time (s)
  "Interpret a time comparison value S as a floating point time.

S can be an Org time stamp, a modifier, e.g., \"<+2d>\", or the
following special strings: \"<now>\", \"<today>\",
\"<tomorrow>\", and \"<yesterday>\".

Return 0. if S is not recognized as a valid value."
  (let ((today (float-time (apply #'encode-time
				  (append '(0 0 0) (nthcdr 3 (decode-time)))))))
    (save-match-data
      (cond
       ((string= s "<now>") (float-time))
       ((string= s "<today>") today)
       ((string= s "<tomorrow>") (+ 86400.0 today))
       ((string= s "<yesterday>") (- today 86400.0))
       ((string-match "\\`<\\([-+][0-9]+\\)\\([hdwmy]\\)>\\'" s)
	(+ today
	   (* (string-to-number (match-string 1 s))
	      (cdr (assoc (match-string 2 s)
			  '(("d" . 86400.0)   ("w" . 604800.0)
			    ("m" . 2678400.0) ("y" . 31557600.0)))))))
       ((string-match org-ts-regexp0 s) (org-2ft s))
       (t 0.)))))



(provide 'org-macs)

;;; org-macs.el ends here
