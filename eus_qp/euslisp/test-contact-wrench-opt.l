(load "package://eus_qp/euslisp/contact-optimization.l")
(load "package://eus_qp/euslisp/eiquadprog.l")
(load "package://eus_qpoases/euslisp/eus-qpoases.l")

(defun setup ()
  ;;(setup-model-for-hrp2)
  ;; (unless (boundp '*robot*)
  ;;   (load "package://hrpsys_ros_bridge_tutorials/models/hrp2jsk.l")
  ;;   (setq *robot* (hrp2jsk)))
  (unless (boundp '*robot*)
    (load "irteus/demo/sample-robot-model.l")
    (setq *robot* (instance sample-robot :init))
    (send-all (send *robot* :joint-list) :max-joint-torque 15.0))
  (unless (boundp '*cbox*)
    (load "models/cardboard-box-object.l")
    (setq *cbox* (cardboard-box))
    (send (car (send *cbox* :links)) :weight 20000.0) ;; 20kg
    (let ((ccoords2 (make-cascoords :coords (send (send *cbox* :copy-worldcoords) :transform (make-coords :pos (float-vector 0 215 185) :rpy (list 0 0 pi/2))))))
      (send *cbox* :assoc ccoords2)
      (send *cbox* :put :face-coords-2 ccoords2)))
  (unless (boundp '*irtviewer*)
    (make-irtviewer))
  (send *robot* :put :contact-constraint-list
        (mapcar #'(lambda (l)
                    (instance* default-contact-constraint
                              :init
                              :mu-trans 0.5
                              :mu-rot 0.05
                              (let* ((vs (mapcar #'(lambda (v) (send *robot* l :end-coords :inverse-transform-vector v)) (send (send *robot* :support-polygon l) :vertices))))
                                (list :l-min-x (elt (find-extream vs #'(lambda (v) (elt v 0)) #'<) 0)
                                      :l-max-x (elt (find-extream vs #'(lambda (v) (elt v 0)) #'>) 0)
                                      :l-min-y (elt (find-extream vs #'(lambda (v) (elt v 1)) #'<) 1)
                                      :l-max-y (elt (find-extream vs #'(lambda (v) (elt v 1)) #'>) 1)
                                      ))))
                '(:rleg :lleg)))
  (objects (list *robot*))
  )

(defmacro with-set-color-line-width ;; just for coloring
  (vw color line-width &rest bodies)
  (with-gensyms
   (prev-color prev-width)
   `(let* ((,prev-color (send ,vw :viewsurface :color))
	   (,prev-width (send ,vw :viewsurface :line-width)))
      (unwind-protect
	  (progn
	    (send ,vw :viewsurface :color ,color)
	    (send ,vw :viewsurface :line-width ,line-width)
	    ,@bodies)
	(send ,vw :viewsurface :color ,prev-color)
	(send ,vw :viewsurface :line-width ,prev-width)
	))))

(defun draw-force-value
  (ret-list
   &key (union-link-list)
        (robot *robot*)
        (limbs '(:rleg :lleg))
        (contact-coords-list (mapcar #'(lambda (l) (send robot l :end-coords)) limbs)))
  ;; draw contact wrench
  (send-all (send robot :get :contact-constraint-list) :draw-on :flush nil)
  (mapcar
   #'(lambda (f m cc)
       ;; draw cop
       (let* ((cop (send robot :calc-cop-from-force-moment ;; dummy using of robot
                         f m cc cc)))
         (when cop (send cop :draw-on :flush nil :color #F(1 0 0) :width 4 :size 30))))
   (car (cadr (memq :wrench-list ret-list))) (cadr (cadr (memq :wrench-list ret-list))) contact-coords-list)
  (mapcar
   #'(lambda (f m cc)
       ;; draw force
       (with-set-color-line-width
        *viewer* #F(1 0.3 1) 5
        (send *irtviewer* :viewer :draw-arrow
              (send cc :worldpos)
              (v+ (send cc :worldpos) (scale 1 f)))))
   (car (cadr (memq :wrench-list ret-list))) (cadr (cadr (memq :wrench-list ret-list))) contact-coords-list)
  ;; draw torque
  (if (cadr (memq :torque-vector ret-list))
      (with-set-color-line-width
       *viewer* #F(0 1 1) 5
       (send robot :draw-torque *viewer*
             :torque-vector (cadr (memq :torque-vector ret-list))
             :joint-list (send-all union-link-list :joint))))
  (send *irtviewer* :viewer :viewsurface :flush)
  )

(defun test-wrench-distribute-by-pseudo-inverse
  (&key (contact-coords-list (mapcar #'(lambda (l) (send *robot* l :end-coords)) '(:rleg :lleg))))
  (let ((ret
         (list :wrench-list
               (send *robot* :calc-contact-wrenches-from-total-wrench
                     (send-all contact-coords-list :worldpos)))))
    ;; just for drawing
    (mapcar #'(lambda (c-constraint c-coords)
                (send c-constraint :update-contact-coords c-coords))
            (send *robot* :get :contact-constraint-list) contact-coords-list)
    (draw-force-value ret)
    (send *irtviewer* :viewer :viewsurface :flush)
    ret))

(defun test-wrench-distribute-by-qp
  (&key (contact-coords-list (mapcar #'(lambda (l) (send *robot* l :end-coords)) '(:rleg :lleg)))
        (contact-constraint-matrix-list))
  (unless contact-constraint-matrix-list
    (setq contact-constraint-matrix-list
          (mapcar #'(lambda (c-constraint c-coords)
                      (send c-constraint :calc-constraint-matrix c-coords))
                  (send *robot* :get :contact-constraint-list) contact-coords-list)))
  (send *robot* :calc-torque :calc-statics-p t)
  (let ((ret
         (wrench-distribute-from-total-wrench
          contact-coords-list contact-constraint-matrix-list
          :robot *robot*
          :contact-constraint-vector-list (send-all (send *robot* :get :contact-constraint-list) :get-constraint-vector))))
    (draw-force-value ret)
    (send *irtviewer* :viewer :viewsurface :flush)
    ret))

(defun test-wrench-torque-distribute-by-qp
  (&key (contact-coords-list (mapcar #'(lambda (l) (send *robot* l :end-coords)) '(:rleg :lleg)))
        (contact-constraint-matrix-list)
        (func #'wrench-torque-distribute-from-total-wrench-inertial-torque))
  (unless contact-constraint-matrix-list
    (setq contact-constraint-matrix-list
          (mapcar #'(lambda (c-constraint c-coords)
                      (send c-constraint :calc-constraint-matrix c-coords))
                  (send *robot* :get :contact-constraint-list) contact-coords-list)))
  (send *robot* :calc-torque :calc-statics-p t)
  (let* ((link-list
          (mapcar #'(lambda (x) (send *robot* :link-list (send x :parent)))
                  contact-coords-list))
         (union-link-list (send *robot* :calc-union-link-list link-list))
         (ret (funcall func
                       contact-coords-list contact-constraint-matrix-list
                       :robot *robot*
                       :contact-constraint-vector-list (send-all (send *robot* :get :contact-constraint-list) :get-constraint-vector)
                       )))
    (draw-force-value ret :union-link-list union-link-list)
    (send *irtviewer* :viewer :viewsurface :flush)
    ret))

(defun test-distribute-all
  (&key (func #'test-wrench-distribute-by-qp) (press-enter-p t))
  (let ((ret))
    (send *robot* :reset-pose)
    (send *robot* :fix-leg-to-coords (make-coords))
    (send *irtviewer* :draw-objects)
    (push (funcall func) ret)
    (when press-enter-p (format t ";; press enter~%") (read-line))
    (send *robot* :reset-pose)
    (send *robot* :fix-leg-to-coords (make-coords))
    (send *robot* :legs :move-end-pos #f(0 0 50))
    (send *robot* :fix-leg-to-coords (make-coords))
    (send *robot* :lleg :move-end-pos #f(100 50 0))
    (send *robot* :move-centroid-on-foot :rleg '(:rleg :lleg))
    (send *irtviewer* :draw-objects)
    (push (funcall func) ret)
    (when press-enter-p (format t ";; press enter~%") (read-line))
    (send *robot* :reset-pose)
    (send *robot* :fix-leg-to-coords (make-coords :pos #f(200 200 300)))
    (send *irtviewer* :draw-objects)
    (push (funcall func) ret)
    (when press-enter-p (format t ";; press enter~%") (read-line))
    (send *robot* :reset-pose)
    (send *robot* :fix-leg-to-coords (make-coords))
    (send *robot* :lleg :move-end-pos #f(-100 0 50) :world)
    (send *robot* :rleg :move-end-rot -40 :y)
    (send *robot* :lleg :move-end-rot 40 :y)
    (send *robot* :rleg :move-end-rot -10 :x)
    (send *robot* :lleg :move-end-rot 10 :x)
    (send *robot* :rleg :move-end-rot -5 :z)
    (send *robot* :lleg :move-end-rot 5 :z)
    (send *robot* :move-centroid-on-foot :both '(:rleg :lleg))
    (send *irtviewer* :draw-objects)
    (push (funcall func) ret)
    (every #'identity (reverse ret))))

(warn ";; (setup)~%")
(warn ";; (test-distribute-all :func #'test-wrench-torque-distribute-by-qp)~%")
(warn ";; (test-distribute-all :func #'test-wrench-distribute-by-qp)~%")
(warn ";; (test-distribute-all :func #'test-wrench-distribute-by-pseudo-inverse)~%")
(warn ";; (test-compare-wrench-torque-calc)~%")

(defun calc-diff-wrench
  (tq-wr-list1 tq-wr-list2)
  (distance (send *robot* :wrench-list->wrench-vector (cadr (memq :wrench-list tq-wr-list1)))
            (send *robot* :wrench-list->wrench-vector (cadr (memq :wrench-list tq-wr-list2))))
  )

(defun calc-diff-torque
  (tq-wr-list1 tq-wr-list2)
  (distance (cadr (memq :torque-vector tq-wr-list1)) (cadr (memq :torque-vector tq-wr-list2)))
  )

(defun test-compare-wrench-torque-calc ()
  (let* ((ret1
          (bench :print-string "wrench torque distribute"
                 (test-distribute-all
                  :func #'test-wrench-torque-distribute-by-qp
                  :press-enter-p nil)))
         (ret2
          (bench :print-string "wrench torque distribute old"
                 (test-distribute-all
                  ;; does not work?
                  ;;:func #'(lambda (&rest args) (apply #'test-wrench-torque-distribute-by-qp :func #'wrench-torque-distribute-from-total-wrench-inertial-torque-old args))
                  :func #'test-wrench-torque-distribute-by-qp
                  :press-enter-p nil)))
         (ret3
          (bench :print-string "wrench distribute qp"
                 (test-distribute-all
                  :func #'test-wrench-distribute-by-qp
                  :press-enter-p nil)))
         (ret4
          (bench :print-string "wrench distribute pinv"
                 (test-distribute-all
                  :func #'test-wrench-distribute-by-pseudo-inverse
                  :press-enter-p nil))))
    (format t ";; wrench torque dist vs wrench torque dist old~%")
    (format t ";;   diff wrench ~A, diff torque ~A~%"
            (mapcar #'calc-diff-wrench ret1 ret2) (mapcar #'calc-diff-torque ret1 ret2))
    (format t ";; wrench torque dist vs wrench dist~%")
    (format t ";;   diff wrench ~A (wrench torque ~A, wrench ~A)~%"
            (mapcar #'calc-diff-wrench ret1 ret3)
            (mapcar #'(lambda (x) (norm (send *robot* :wrench-list->wrench-vector (cadr (memq :wrench-list x))))) ret1)
            (mapcar #'(lambda (x) (norm (send *robot* :wrench-list->wrench-vector (cadr (memq :wrench-list x))))) ret3))
    (format t ";; wrench dist qp vs wrench dist pinv~%")
    (format t ";;   diff wrench ~A (wrench dist qp ~A, wrench dist pinv ~A)~%"
            (mapcar #'calc-diff-wrench ret3 ret4)
            (mapcar #'(lambda (x) (norm (send *robot* :wrench-list->wrench-vector (cadr (memq :wrench-list x))))) ret3)
            (mapcar #'(lambda (x) (norm (send *robot* :wrench-list->wrench-vector (cadr (memq :wrench-list x))))) ret4))
    ))

(defun demo-cbox-wrench-calc-comon
  (contact-constraint-list
   contact-coords-list)
  (send *cbox* :put :contact-constraint-list contact-constraint-list)
  ;; calc total static wrench
  (send *cbox* :calc-torque :calc-statics-p t)
  (let ((ret
         (wrench-distribute-from-total-wrench
          contact-coords-list
          (mapcar #'(lambda (c-constraint c-coords)
                      (send c-constraint :calc-constraint-matrix c-coords))
                  contact-constraint-list contact-coords-list)
          :robot *cbox*
          :contact-constraint-vector-list (send-all contact-constraint-list :get-constraint-vector))))
    (draw-force-value
     ret :limbs nil :robot *cbox*
     :contact-coords-list contact-coords-list)
    ret))

(defun set-cbox-pose-neutral
  ()
  (send *cbox* :newcoords (make-coords))
  (objects (list *cbox*))
  )

(defun set-cbox-pose-tilting
  ()
  ;; move models
  (send *cbox* :newcoords (make-coords))
  (send *cbox* :rotate (deg2rad -30) :x)
  (send *cbox* :rotate (deg2rad -10) :y)
  (objects (list *cbox*))
  )

(defun demo-cbox-wrench-calc-1
  ()
  "Demo for cbox wrench calculation by default-contact-constraint. cbox is neutral pos rot."
  (set-cbox-pose-neutral)
  (demo-cbox-wrench-calc-comon
   ;; setup contact constraint
   ;; box size 190, 215, 185
   (list (instance default-contact-constraint
                   :init
                   :mu-trans 0.5 :mu-rot 0.05
                   :l-min-x -190 :l-max-x 190
                   :l-min-y -215 :l-max-y 215))
   (list (send *cbox* :worldcoords))
   ))

(defun demo-cbox-wrench-calc-2
  ()
  "Demo for cbox wrench calculation by norm-contact-constraint. cbox is neutral pos rot."
  (set-cbox-pose-neutral)
  (demo-cbox-wrench-calc-comon
   (list (instance norm-contact-constraint :init :fz))
   (list (send *cbox* :worldcoords))
   ))

(defun demo-cbox-wrench-calc-3
  ()
  "Demo for cbox wrench calculation by 2D-translational-friction-contact-constraint. cbox is neutral pos rot."
  (set-cbox-pose-neutral)
  (demo-cbox-wrench-calc-comon
   (list (instance 2D-translational-friction-contact-constraint :init 0.5))
   (list (send *cbox* :worldcoords))
   ))

(defun demo-cbox-wrench-calc-4
  ()
  "Demo for cbox wrench calculation by rotational-friction-contact-constraint. cbox is neutral pos rot."
  (set-cbox-pose-neutral)
  (demo-cbox-wrench-calc-comon
   (list (instance rotational-friction-contact-constraint :init 0.05 :fz))
   (list (send *cbox* :worldcoords))
   ))

(defun demo-cbox-wrench-calc-5
  ()
  "Demo for cbox wrench calculation by 2D-cop-contact-constraint. cbox is neutral pos rot."
  (set-cbox-pose-neutral)
  (demo-cbox-wrench-calc-comon
   (list (instance 2D-cop-contact-constraint :init 190 -190 215 -215))
   (list (send *cbox* :worldcoords))
   ))

(defun demo-cbox-wrench-calc-6
  (&key (mu-trans 0.5) (l-min-x -190) (l-max-x 190))
  "Demo for cbox wrench calculation by default-contact-constraint. cbox is tilting."
  (set-cbox-pose-tilting)
  (demo-cbox-wrench-calc-comon
   ;; setup contact constraint
   ;; box size 190, 215, 185
   (list (instance default-contact-constraint
                   :init
                   :mu-trans mu-trans :mu-rot 0.05
                   :l-min-x l-min-x :l-max-x l-max-x
                   :l-min-y -215 :l-max-y 215)
         (instance default-contact-constraint
                   :init
                   :mu-trans mu-trans :mu-rot 0.05
                   :l-min-x l-min-x :l-max-x l-max-x
                   :l-min-y -185 :l-max-y 185)
         )
   (list (send *cbox* :worldcoords) (send *cbox* :get :face-coords-2))
   ))

(defun demo-cbox-wrench-calc-7
  ()
  "Demo for cbox wrench calculation by norm-contact-constraint. cbox is tilting."
  (set-cbox-pose-tilting)
  (demo-cbox-wrench-calc-comon
   (list (instance norm-contact-constraint :init :fz) (instance norm-contact-constraint :init :fz))
   (list (send *cbox* :worldcoords) (send *cbox* :get :face-coords-2))
   ))

(defun demo-cbox-wrench-calc-8
  ()
  "Demo for cbox wrench calculation by 2D-translational-friction-contact-constraint. cbox is tilting."
  (set-cbox-pose-tilting)
  (demo-cbox-wrench-calc-comon
   (list (instance 2D-translational-friction-contact-constraint :init 0.5) (instance 2D-translational-friction-contact-constraint :init 0.5))
   (list (send *cbox* :worldcoords) (send *cbox* :get :face-coords-2))
   ))

(defun demo-cbox-wrench-calc-9
  ()
  "Demo for cbox wrench calculation by rotational-friction-contact-constraint. cbox is tilting."
  (set-cbox-pose-tilting)
  (demo-cbox-wrench-calc-comon
   (list (instance rotational-friction-contact-constraint :init 0.05 :fz) (instance rotational-friction-contact-constraint :init 0.05 :fz))
   (list (send *cbox* :worldcoords) (send *cbox* :get :face-coords-2))
   ))

(defun demo-cbox-wrench-calc-10
  ()
  "Demo for cbox wrench calculation by 2D-cop-contact-constraint. cbox is tilting."
  (set-cbox-pose-tilting)
  (demo-cbox-wrench-calc-comon
   ;; setup contact constraint
   ;; box size 190, 215, 185
   (list (instance 2D-cop-contact-constraint :init 190 -190 215 -215)
         (instance 2D-cop-contact-constraint :init 190 -190 185 -185))
   (list (send *cbox* :worldcoords) (send *cbox* :get :face-coords-2))
   ))

(defun demo-cbox-wrench-calc-11
  ()
  "Demo for cbox wrench calculation by default-contact-constraint. cbox is tilting. Infeasible solution."
  (set-cbox-pose-tilting)
  (not
   (demo-cbox-wrench-calc-comon
    ;; setup contact constraint
    ;; box size 190, 215, 185
    (list (instance default-contact-constraint
                    :init
                    :mu-trans 0.05 :mu-rot 0.05
                    :l-min-x -50 :l-max-x 50
                    :l-min-y -50 :l-max-y 50)
          (instance default-contact-constraint
                    :init
                    :mu-trans 0.05 :mu-rot 0.05
                    :l-min-x -50 :l-max-x 50
                    :l-min-y -50 :l-max-y 50)
          )
    (list (send *cbox* :worldcoords) (send *cbox* :get :face-coords-2))
    )))

(defun demo-cbox-wrench-calc-12
  ()
  "Demo for cbox wrench calculation by min-max-contact-constraint. cbox is tilting."
  (set-cbox-pose-tilting)
  (demo-cbox-wrench-calc-comon
   (list (instance min-max-contact-constraint
                   :init :fz 40.0 :min/max :max)
         (instance min-max-contact-constraint
                   :init :nz 5.0 :min/max :min))
   (list (send *cbox* :worldcoords) (send *cbox* :get :face-coords-2))
   ))

(defun demo-cbox-wrench-calc-13
  ()
  "Demo for cbox wrench calculation by 2D-translational-sliding-contact-constraint. cbox is neutral pos rot. This sample is infeasible but it's correct."
  (set-cbox-pose-neutral)
  (not
   (demo-cbox-wrench-calc-comon
    (list (instance 2D-translational-sliding-contact-constraint :init 0.5 :slide-axis :x))
    (list (send *cbox* :worldcoords))
    )))

(defun demo-cbox-wrench-calc-14
  ()
  "Demo for cbox wrench calculation by default-contact-constraint. cbox is neutral pos rot. cbox is sliding in the -y direction."
  (set-cbox-pose-neutral)
  (demo-cbox-wrench-calc-comon
   (list (instance default-contact-constraint
                   :init
                   :mu-trans 0.5 :mu-rot 0.05
                   :slide-axis :-y
                   :l-min-x -150 :l-max-x 150
                   :l-min-y -150 :l-max-y 150)
         (instance default-contact-constraint
                   :init
                   :mu-trans 0.05 :mu-rot 0.05
                   :l-min-x -50 :l-max-x 50
                   :l-min-y -50 :l-max-y 50))
   (list (send *cbox* :worldcoords) (send *cbox* :get :face-coords-2))
   ))

(defun demo-cbox-wrench-calc-all
  (&key (press-enter-p t))
  (let ((ret))
    (dotimes (i 14)
      (format t ";; demo-cbox-wrench-calc-~d~%" (1+ i))
      (push (funcall (eval (read-from-string (format nil "#'demo-cbox-wrench-calc-~d" (1+ i))))) ret)
      (when press-enter-p (format t ";; press enter~%") (read-line)))
    (every #'identity ret)
    ))

;; Usage
(warn ";; cbox demo functions~%")
(dotimes (i 14)
  (warn ";;   (demo-cbox-wrench-calc-~d) ;; ~A~%" (1+ i)
        (documentation (read-from-string (format nil "demo-cbox-wrench-calc-~d" (1+ i))))))
(warn ";;   (demo-cbox-wrench-calc-all) ;; for all tests~%")

#|
(defun test-wrench-comp ()
  (let* ((contact-coords-list
          (mapcar #'(lambda (l) (send *hrp2* l :end-coords)) '(:rleg :lleg :rarm :larm))))
  (labels ((calc-wrench
            ()
            (dotimes (i 3) (send *hrp2* :calc-torque :dt 0.005 :calc-statics-p nil))
            (concatenate float-vector
                         (send (car (send *hrp2* :links)) :force)
                         (send (car (send *hrp2* :links)) :moment))
            )
           (comp-wrench
            (weight)
            (let ((ret-pseudo-inverse
                   (send *hrp2* :calc-contact-wrenches-from-total-wrench
                         (send-all contact-coords-list :worldpos) :total-wrench (calc-wrench)
                         :weight weight))
                  (opt-weight (copy-object weight)))
              (dotimes (i (length opt-weight)) (setf (elt opt-weight i) (/ 1.0 (elt weight i))))
              (let* ((ret-qp
                      (wrench-distribute-from-total-wrench
                       contact-coords-list
                       nil
                       (v- (calc-wrench))
                       :robot *hrp2*
                       :optimize-weight-vector opt-weight)))
                ;;(print ret-pseudo-inverse)
                ;;(print ret-qp)
                (mapcar #'(lambda (f1 m1 f2 m2)
                            (and (eps-v= f1 f2) (eps-v= m1 m2)))
                        (car ret-pseudo-inverse) (cadr ret-pseudo-inverse)
                        (car ret-qp) (cadr ret-qp))
                ))))
    (let* ((weight (fill (instantiate float-vector (* 6 (length contact-coords-list))) 1)))
      (print (comp-wrench weight))
      (dotimes (i 6)
        (setf (elt weight i) 0.5)
        (setf (elt weight (+ 12 i)) 0.5)
        )
      (print (comp-wrench weight))
      (dotimes (i 6)
        (setf (elt weight i) 1e-5)
        (setf (elt weight (+ 12 i)) 1e-5)
        )
      (print (comp-wrench weight))
      (dotimes (i 6)
        (setf (elt weight i) 1e-9)
        (setf (elt weight (+ 12 i)) 1e-9)
        )
      (print (comp-wrench weight))
      t))))
|#