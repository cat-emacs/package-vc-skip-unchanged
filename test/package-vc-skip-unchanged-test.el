;;; package-vc-skip-unchanged-test.el --- Tests for package-vc-skip-unchanged -*- lexical-binding: t; -*-

(require 'ert)
(require 'package-vc-skip-unchanged)

(ert-deftest package-vc-skip-unchanged-mode-controls-override ()
  (should-not package-vc-skip-unchanged-mode)
  (should-not
   (advice-member-p #'package-vc-skip-unchanged-upgrade-all
                    'package-vc-upgrade-all))
  (should-not
   (advice-member-p #'package-vc-skip-unchanged-upgrade
                    'package-vc-upgrade))
  (unwind-protect
      (progn
        (package-vc-skip-unchanged-mode 1)
        (should
         (advice-member-p #'package-vc-skip-unchanged-upgrade-all
                          'package-vc-upgrade-all))
        (should
         (advice-member-p #'package-vc-skip-unchanged-upgrade
                          'package-vc-upgrade)))
    (package-vc-skip-unchanged-mode -1))
  (should-not
   (advice-member-p #'package-vc-skip-unchanged-upgrade-all
                    'package-vc-upgrade-all))
  (should-not
   (advice-member-p #'package-vc-skip-unchanged-upgrade
                    'package-vc-upgrade)))

(ert-deftest package-vc-skip-unchanged-skips-direct-upgrade ()
  (let* ((desc (package-desc-create
                :name 'cat-vc-test :version '(0) :summary "Test"
                :kind 'vc :dir default-directory))
         (fetch-count 0)
         (same-revision t)
         (upgrade-count 0))
    (cl-letf (((symbol-function 'vc-responsible-backend)
               (lambda (_dir) 'Git))
              ((symbol-function 'package-vc-skip-unchanged--fetch-upstream)
               (lambda (_pkg-desc) (cl-incf fetch-count)))
              ((symbol-function 'package-vc-skip-unchanged--same-revision-p)
               (lambda (_pkg-desc) same-revision))
              ((symbol-function 'package-vc-upgrade)
               (lambda (_pkg-desc) (cl-incf upgrade-count))))
      (unwind-protect
          (progn
            (package-vc-skip-unchanged-mode 1)
            (package-vc-upgrade desc)
            (should (= fetch-count 1))
            (should (= upgrade-count 0))
            (setq same-revision nil)
            (package-vc-upgrade desc)
            (should (= fetch-count 2))
            (should (= upgrade-count 1)))
        (package-vc-skip-unchanged-mode -1)))))

(ert-deftest package-vc-skip-unchanged-covers-package-upgrade-all ()
  (let* ((desc (package-desc-create
                :name 'cat-vc-test :version '(0) :summary "Test"
                :kind 'vc :dir default-directory))
         (package-alist `((cat-vc-test ,desc)))
         (fetch-count 0)
         (upgrade-count 0))
    (cl-letf (((symbol-function 'package-refresh-contents) #'ignore)
              ((symbol-function 'package--upgradeable-packages)
               (lambda (&optional _include-builtins) '(cat-vc-test)))
              ((symbol-function 'vc-responsible-backend)
               (lambda (_dir) 'Git))
              ((symbol-function 'package-vc-skip-unchanged--fetch-upstream)
               (lambda (_pkg-desc) (cl-incf fetch-count)))
              ((symbol-function 'package-vc-skip-unchanged--same-revision-p)
               (lambda (_pkg-desc) t))
              ((symbol-function 'package-vc-upgrade)
               (lambda (_pkg-desc) (cl-incf upgrade-count))))
      (unwind-protect
          (progn
            (package-vc-skip-unchanged-mode 1)
            (package-upgrade-all nil)
            (should (= fetch-count 1))
            (should (= upgrade-count 0)))
        (package-vc-skip-unchanged-mode -1)))))

(ert-deftest package-vc-skip-unchanged-calls-failing-native-upgrade-once ()
  (let* ((desc (package-desc-create
                :name 'cat-vc-test :version '(0) :summary "Test"
                :kind 'vc :dir default-directory))
         (upgrade-count 0))
    (cl-letf (((symbol-function 'vc-responsible-backend)
               (lambda (_dir) 'Hg))
              ((symbol-function 'package-vc-upgrade)
               (lambda (_pkg-desc)
                 (cl-incf upgrade-count)
                 (error "Native upgrade failed"))))
      (unwind-protect
          (progn
            (package-vc-skip-unchanged-mode 1)
            (should-error (package-vc-upgrade desc)
                          :type 'error)
            (should (= upgrade-count 1)))
        (package-vc-skip-unchanged-mode -1)))))

(ert-deftest package-vc-skip-unchanged-skips-matching-hashes-concurrently ()
  (let* ((root (make-temp-file "package-vc-skip-unchanged-test-" t))
         (git (expand-file-name "git" root))
         (package-alist nil)
         (package-vc-skip-unchanged-max-concurrency 2)
         (direct-fetch-count 0)
         (upgrade-count 0))
    (unwind-protect
        (progn
          (with-temp-file git
            (insert "#!/bin/sh\n"
                    "case \" $* \" in\n"
                    "  *' fetch '*) sleep 0.2 ;;\n"
                    "  *' rev-parse '*)\n"
                    "    case \"$PWD:$*\" in\n"
                    "      *cat-vc-test-0*' @{u}'*) echo remote-hash ;;\n"
                    "      *) echo same-hash ;;\n"
                    "    esac\n"
                    "    ;;\n"
                    "esac\n"))
          (set-file-modes git #o755)
          (dotimes (index 4)
            (let* ((name (intern (format "cat-vc-test-%d" index)))
                   (dir (expand-file-name (symbol-name name) root))
                   (desc (package-desc-create
                          :name name :version '(0) :summary "Test"
                          :kind 'vc :dir dir)))
              (make-directory dir)
              (push (list name desc) package-alist)))
          (let ((vc-git-program git))
            (cl-letf (((symbol-function 'vc-responsible-backend)
                       (lambda (_dir) 'Git))
                      ((symbol-function 'package-vc-upgrade)
                       (lambda (_pkg-desc)
                         (cl-incf upgrade-count)))
                      ((symbol-function 'package-vc-skip-unchanged--fetch-upstream)
                       (lambda (_pkg-desc) (cl-incf direct-fetch-count))))
              (package-vc-skip-unchanged-mode 1)
              (let ((noninteractive nil))
                (package-vc-upgrade-all)
                (should
                 (= 2 (cl-count-if
                       (lambda (process)
                         (and (string-prefix-p
                               "package-vc-skip-unchanged-fetch-"
                                               (process-name process))
                              (process-get process 'package-vc-skip-unchanged--package)
                              (process-live-p process)))
                       (process-list)))))
              (while (and (boundp 'package-vc-skip-unchanged--upgrade-state)
                          package-vc-skip-unchanged--upgrade-state)
                (accept-process-output nil 0.05))
              (should (= upgrade-count 1))
              (should (= direct-fetch-count 0)))))
      (package-vc-skip-unchanged-mode -1)
      (setq package-vc-skip-unchanged--upgrade-state nil)
      (delete-directory root t))))

(defun package-vc-skip-unchanged-test--git (root name &rest args)
  "Run Git with ARGS in the NAME repository under ROOT."
  (let ((default-directory (expand-file-name name root)))
    (apply #'process-file "git" nil nil nil args)))

(defun package-vc-skip-unchanged-test--make-remote (root)
  "Create an upstream repository under ROOT and return its directory."
  (let ((dir (expand-file-name "remote" root)))
    (make-directory dir)
    (package-vc-skip-unchanged-test--git root "remote" "init" "--quiet"
                                        "--initial-branch" "main")
    (package-vc-skip-unchanged-test--git root "remote" "config"
                                        "user.email" "test@example.com")
    (package-vc-skip-unchanged-test--git root "remote" "config"
                                        "user.name" "Test")
    (with-temp-file (expand-file-name "pkg.el" dir)
      (insert ";;; pkg.el --- Test -*- lexical-binding: t; -*-\n"))
    (package-vc-skip-unchanged-test--git root "remote" "add" "pkg.el")
    (package-vc-skip-unchanged-test--git root "remote" "commit" "--quiet"
                                        "-m" "Initial")
    dir))

(ert-deftest package-vc-skip-unchanged-detects-detached-head-as-unchanged ()
  "A detached checkout at the upstream commit must count as unchanged.
`package-vc' checks packages out at an explicit revision, so \"@{u}\"
cannot resolve an upstream branch."
  (let* ((root (make-temp-file "package-vc-skip-unchanged-detached-" t))
         (remote (package-vc-skip-unchanged-test--make-remote root))
         (clone (expand-file-name "clone" root))
         (desc (package-desc-create
                :name 'cat-vc-detached :version '(0) :summary "Test"
                :kind 'vc :dir clone)))
    (unwind-protect
        (progn
          (package-vc-skip-unchanged-test--git
           root "." "clone" "--quiet" remote clone)
          (let ((head (string-trim
                       (with-output-to-string
                         (let ((default-directory clone))
                           (process-file "git" nil standard-output nil
                                         "rev-parse" "HEAD"))))))
            (package-vc-skip-unchanged-test--git
             root "clone" "checkout" "--quiet" "--detach" head)
            ;; Guard the precondition the fix is about.
            (should-not
             (package-vc-skip-unchanged--git-string desc "rev-parse" "@{u}"))
            (should (equal (package-vc-skip-unchanged--remote desc) "origin"))
            (should (equal (package-vc-skip-unchanged--upstream-revision desc)
                           head))
            (should (package-vc-skip-unchanged--same-revision-p desc))
            ;; A new upstream commit must still be detected.
            (with-temp-file (expand-file-name "pkg.el" remote)
              (insert ";;; pkg.el --- Test -*- lexical-binding: t; -*-\n"
                      "(provide 'pkg)\n"))
            (package-vc-skip-unchanged-test--git root "remote" "commit" "--quiet"
                                                "-am" "Update")
            (package-vc-skip-unchanged--fetch-upstream desc)
            (should-not (package-vc-skip-unchanged--same-revision-p desc))))
      (delete-directory root t))))

(provide 'package-vc-skip-unchanged-test)
;;; package-vc-skip-unchanged-test.el ends here
