;;; refs.el --- find callers of elisp functions or macros  -*- lexical-binding: t; -*-

;; Copyright (C) 2016  

;; Author: Wilfred Hughes <me@wilfred.me.uk>
;; Version: 0.1
;; Keywords: lisp
;; Package-Requires: ((dash "2.12.0") (f "0.18.2") (ht "2.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A package for finding callers of elisp functions or macros. Really
;; useful for finding examples.

;;; Code:

(require 'dash)
(require 'f)
(require 'ht)

(defun refs--find-start-offset (string sexp-end)
  "Find the matching start offset in STRING for
sexp ending at SEXP-END."
  (with-temp-buffer
    (insert string)
    ;; Point is 1-indexed.
    (goto-char (1+ sexp-end))
    ;; TODO: write in terms of `scan-sexps'.
    (forward-sexp -1)
    (1- (point))))

(defun refs--read-with-offsets (string offsets start-offset)
  "Read a form from STRING, starting from offset START-OFFSET.
Assumes that START-OFFSET is not inside a string or comment.

For each subform, record the start and end offsets in hash table
OFFSETS."
  (condition-case _err
      (progn
        (-let* (((form . end-offset) (read-from-string string start-offset))
                (start-offset (refs--find-start-offset string end-offset)))
          ;; TODO: Handle vector literals.
          ;; TODO: handle ' and `.
          (when (consp form)
            ;; Recursively read the subelements of the form.
            (let ((next-subform (refs--read-with-offsets
                                 string offsets (1+ start-offset))))
              (while next-subform
                (setq next-subform
                      (refs--read-with-offsets
                       string offsets (refs--end-offset next-subform offsets))))))
          ;; This is lossy: if we read multiple identical forms, we
          ;; only store the position of the last one. TODO: store all.
          (ht-set! offsets form (list start-offset end-offset))
          form))
    ;; reached a closing paren.
    (invalid-read-syntax nil)))

(defun refs--read-all-with-offsets (string)
  "Read all the forms from STRING.
We return a list of all the forms, along with a hash table
mapping each form to its start and end offset."
  (let ((offsets (ht-create))
        (pos 0)
        (forms nil))
    ;; Read forms until we hit EOF, which raises an error.
    (ignore-errors
      (while t
        (let ((form (refs--read-with-offsets string offsets pos)))
          (push form forms)
          (setq pos (refs--end-offset form offsets)))))
    (list (nreverse forms) offsets)))

(defun refs--end-offset (form offsets)
  "Given a hash table OFFSETS generated by `refs--read-all-with-offsets',
return the end offset of FORM."
  (-last-item (ht-get offsets form)))

;; TODO: factor out a flat map, and a map that saves us destructuring
;; indexed forms everywhere.
(defun refs--find-calls-1 (form symbol)
  "If FORM contains any calls to SYMBOL, return those subforms.
Returns nil otherwise.

This is basic static analysis, so indirect function calls are
ignored."
  ;; TODO: Handle funcall to static symbols too.
  ;; TODO: Handle sharp-quoted function references.
  ;; TODO: (defun foo (bar baz)) is not a function call to bar.
  (cond
   ;; Base case: are we looking at (symbol ...)?
   ((and (consp form) (eq (car form) symbol))
    (list form))
   ;; Recurse, so we can find (... (symbol ...) ...)
   ((and (consp form) (not (list-utils-improper-p form)))
    (-non-nil (--mapcat (refs--find-calls-1 it symbol) form)))
   ;; If it's not a cons cell, it's not a call.
   (t
    nil)))

(defun refs--find-calls (forms symbol)
  "If FORMS contains any calls to SYMBOL, return those subforms."
  (--mapcat (refs--find-calls-1 it symbol) forms))

(defun refs--functions ()
  "Return a list of all symbols that are variables."
  (let (symbols)
    (mapatoms (lambda (symbol)
                (when (functionp symbol)
                  (push symbol symbols))))
    symbols))

(defun refs--loaded-files ()
  "Return a list of all files that have been loaded in Emacs.
Where the file was a .elc, return the path to the .el file instead."
  (let ((elc-paths (-map #'-first-item load-history)))
    (-non-nil
     (--map
      (let ((el-name (format "%s.el" (f-no-ext it)))
            (el-gz-name (format "%s.el.gz" (f-no-ext it))))
        (cond ((f-exists? el-name) el-name)
              ;; TODO: make refs--file-contents handle gzipped files.
              ;; ((f-exists? el-gz-name) el-gz-name)
              ;; Ignore files where we can't find a .el file.
              (t nil)))
      elc-paths))))

(defun refs--file-contents (path)
  "Return the contents of PATH as a string."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (buffer-string)))

(defun refs--show-results (results)
  "Given a list where each element takes the form \(path . forms\),
render a friendly results buffer."
  ;; TODO: separate buffer per search.
  (let ((buf (get-buffer-create "*refs*")))
    (switch-to-buffer buf)
    (erase-buffer)
    (insert (format "? results in %s files.\n" (length results)))
    (--each results
      (-let [(path . forms) it]
        (insert (format "File: %s\n" (f-short path)))
        (--each forms
          (insert (format "%s\n" it)))
        (insert "\n")))))

;; suggestion: format is a great function to use
;; TODO: profile me, this is slow.
(defun refs-function (symbol)
  "Display all the references to SYMBOL, a function."
  (interactive
   ;; TODO: default to function at point.
   (list (read (completing-read "Function: " (refs--functions)))))

  ;; TODO: build an index and use the full loaded file list.
  (let* ((loaded-paths (-slice (refs--loaded-files) 0 3))
         (loaded-sources (-map #'refs--file-contents loaded-paths))
         (loaded-forms-and-offsets (-map #'refs--read-all-with-offsets loaded-sources))
         (loaded-forms (-map #'-first-item loaded-forms-and-offsets))
         (matching-forms (--map (refs--find-calls it symbol) loaded-forms))
         (all-paths-and-matches (-zip loaded-paths matching-forms))
         (paths-and-matches (--filter (consp (cdr it)) all-paths-and-matches)))
    (refs--show-results paths-and-matches)))

(provide 'refs)
;;; refs.el ends here
