!=======================================================================
!
!  Contains Icepack component driver routines common to all drivers.
!
!  authors Elizabeth C. Hunke, LANL

      module icepack_drv_step_mod

      use icepack_drv_constants
      use icepack_kinds_mod
      implicit none
      private
      save

      public :: step_therm1, step_therm2, step_dyn_ridge, &
                prep_radiation, step_radiation, ocean_mixed_layer, &
                update_state, biogeochemistry

!=======================================================================

      contains

!=======================================================================
!
! Scales radiation fields computed on the previous time step.
!
! authors: Elizabeth Hunke, LANL

      subroutine prep_radiation (dt)

      use icepack_drv_domain_size, only: ncat, nilyr, nslyr, nx
      use icepack_drv_flux, only: scale_factor, swvdr, swvdf, swidr, swidf, &
          alvdr_ai, alvdf_ai, alidr_ai, alidf_ai, fswfac, &
          alvdr_init, alvdf_init, alidr_init, alidf_init
      use icepack_drv_arrays_column, only: fswsfcn, fswintn, fswthrun, &
           fswpenln, Sswabsn, Iswabsn
      use icepack_drv_state, only: aice, aicen

      ! column package includes
      use icepack_intfc, only: icepack_prep_radiation

      real (kind=dbl_kind), intent(in) :: &
         dt      ! time step

      ! local variables

      integer (kind=int_kind) :: &
         i               ! horizontal indices

      real (kind=dbl_kind) :: netsw 

      !-----------------------------------------------------------------
      ! Compute netsw scaling factor (new netsw / old netsw)
      !-----------------------------------------------------------------

         do i = 1, nx

            alvdr_init(i) = alvdr_ai(i)
            alvdf_init(i) = alvdf_ai(i)
            alidr_init(i) = alidr_ai(i)
            alidf_init(i) = alidf_ai(i)

            call icepack_prep_radiation (ncat, nilyr, nslyr,             &
                        aice    (i), aicen   (i,:), &
                        swvdr   (i), swvdf   (i), &
                        swidr   (i), swidf   (i), &
                        alvdr_ai(i), alvdf_ai(i), &
                        alidr_ai(i), alidf_ai(i), &
                        scale_factor(i),                         &
                        fswsfcn (i,:), fswintn (i,:), &
                        fswthrun(i,:), fswpenln(i,:,:), &
                        Sswabsn (i,:,:), Iswabsn (i,:,:))

         enddo               ! i

      end subroutine prep_radiation

!=======================================================================
!
! Driver for updating ice and snow internal temperatures and
! computing thermodynamic growth rates and coupler fluxes.
!
! authors: William H. Lipscomb, LANL

      subroutine step_therm1 (dt)

      use icepack_drv_arrays_column, only: ffracn, dhsn, &
          Cdn_ocn, Cdn_ocn_skin, Cdn_ocn_floe, Cdn_ocn_keel, Cdn_atm_ratio, &
          Cdn_atm, Cdn_atm_skin, Cdn_atm_floe, Cdn_atm_rdg, Cdn_atm_pond, &
          hfreebd, hdraft, hridge, distrdg, hkeel, dkeel, lfloe, dfloe, &
          fswsfcn, fswintn, fswthrun, Sswabsn, Iswabsn
      use icepack_drv_calendar, only: yday, istep1
      use icepack_drv_diagnostics, only: diagnostic_abort
      use icepack_drv_domain_size, only: ncat, nilyr, nslyr, n_aero, nx
      use icepack_drv_flux, only: frzmlt, sst, Tf, strocnxT, strocnyT, rside, fbot, &
          meltsn, melttn, meltbn, congeln, snoicen, uatm, vatm, &
          wind, rhoa, potT, Qa, zlvl, strax, stray, flatn, fsensn, fsurfn, fcondtopn, &
          flw, fsnow, fpond, sss, mlt_onset, frz_onset, &
          frain, Tair, coszen, strairxT, strairyT, fsurf, fcondtop, fsens, &
          flat, fswabs, flwout, evap, Tref, Qref, Uref, fresh, fsalt, fhocn, &
          fswthru, meltt, melts, meltb, meltl, congel, snoice, frazil, &
          flatn_f, fsensn_f, fsurfn_f, fcondtopn_f, &
          dsnown, faero_atm, faero_ocn
      use icepack_drv_init, only: lmask_n, lmask_s
      use icepack_drv_state, only: aice, aicen, aice_init, aicen_init, vicen_init, &
          vice, vicen, vsno, vsnon, trcrn, uvel, vvel, vsnon_init

      ! column packge includes
      use icepack_intfc_tracers, only: ntrcr, &
          nt_apnd, nt_hpnd, nt_ipnd, nt_alvl, nt_vlvl, nt_Tsfc, &
          tr_iage, nt_iage, tr_FY, nt_FY, tr_aero, tr_pond, tr_pond_cesm, &
          tr_pond_lvl, nt_qice, nt_sice, tr_pond_topo, nt_aero, &
          nt_qsno
      use icepack_intfc, only: icepack_step_therm1, &
          icepack_clear_warnings, icepack_print_warnings
      use icepack_intfc_shared, only: calc_Tsfc

      logical (kind=log_kind) :: & 
         prescribed_ice ! if .true., use prescribed ice instead of computed

      real (kind=dbl_kind), intent(in) :: &
         dt      ! time step

      ! local variables

      integer (kind=int_kind) :: &
         i           , & ! horizontal indices
         n              , & ! thickness category index
         k, kk              ! indices for aerosols

      real (kind=dbl_kind), dimension(n_aero,2,ncat) :: &
         aerosno,  aeroice    ! kg/m^2

      logical (kind=log_kind) :: &
         l_stop          ! if true, abort the model

      character (char_len) :: stop_label

      prescribed_ice = .false.
      l_stop = .false.
      aerosno(:,:,:) = c0
      aeroice(:,:,:) = c0

      do i = 1, nx

      !-----------------------------------------------------------------
      ! Save the ice area passed to the coupler (so that history fields
      !  can be made consistent with coupler fields).
      ! Save the initial ice area and volume in each category.
      !-----------------------------------------------------------------

         aice_init (i) = aice (i)

         do n = 1, ncat
            aicen_init(i,n) = aicen(i,n)
            vicen_init(i,n) = vicen(i,n)
            vsnon_init(i,n) = vsnon(i,n)
         enddo

      enddo ! i

      do i = 1, nx
        if (tr_aero) then
          ! trcrn(nt_aero) has units kg/m^3
          do n=1,ncat
            do k=1,n_aero
              aerosno (k,:,n) = &
                  trcrn(i,nt_aero+(k-1)*4  :nt_aero+(k-1)*4+1,n) &
                  * vsnon_init(i,n)
              aeroice (k,:,n) = &
                  trcrn(i,nt_aero+(k-1)*4+2:nt_aero+(k-1)*4+3,n) &
                  * vicen_init(i,n)
            enddo
          enddo
        endif ! tr_aero
        
        call icepack_clear_warnings()
        call icepack_step_therm1(dt, ncat, nilyr, nslyr, n_aero,                &
            aicen_init  (i,:),                           &
            vicen_init  (i,:), vsnon_init  (i,:), &
            aice        (i), aicen       (i,:), &
            vice        (i), vicen       (i,:), &
            vsno        (i), vsnon       (i,:), &
            uvel        (i), vvel        (i), &
            trcrn       (i,nt_Tsfc,:),                   &
            trcrn       (i,nt_qsno:nt_qsno+nslyr-1,:),   & 
            trcrn       (i,nt_qice:nt_qice+nilyr-1,:),   & 
            trcrn       (i,nt_sice:nt_sice+nilyr-1,:),   & 
            trcrn       (i,nt_alvl,:),                   & 
            trcrn       (i,nt_vlvl,:),                   & 
            trcrn       (i,nt_apnd,:),                   & 
            trcrn       (i,nt_hpnd,:),                   & 
            trcrn       (i,nt_ipnd,:),                   & 
            trcrn       (i,nt_iage,:),                   &
            trcrn       (i,nt_FY  ,:),                   & 
            aerosno     (:,:,:),      aeroice     (:,:,:),      &
            uatm        (i), vatm        (i), &
            wind        (i), zlvl        (i), &
            Qa          (i), rhoa        (i), &
            Tair        (i), Tref        (i), &
            Qref        (i), Uref        (i), &
            Cdn_atm_ratio(i),                           &
            Cdn_ocn     (i), Cdn_ocn_skin(i), &
            Cdn_ocn_floe(i), Cdn_ocn_keel(i), &
            Cdn_atm     (i), Cdn_atm_skin(i), &
            Cdn_atm_floe(i), Cdn_atm_pond(i), &
            Cdn_atm_rdg (i), hfreebd     (i), &
            hdraft      (i), hridge      (i), &
            distrdg     (i), hkeel       (i), &
            dkeel       (i), lfloe       (i), &
            dfloe       (i),                           &
            strax       (i), stray       (i), &
            strairxT    (i), strairyT    (i), &
            potT        (i), sst         (i), &
            sss         (i), Tf          (i), &
            strocnxT    (i), strocnyT    (i), &
            fbot        (i),                           &
            frzmlt      (i), rside       (i), &
            fsnow       (i), frain       (i), &
            fpond       (i),                           &
            fsurf       (i), fsurfn      (i,:), &
            fcondtop    (i), fcondtopn   (i,:), &
            fswsfcn     (i,:), fswintn     (i,:), &
            fswthrun    (i,:), fswabs      (i), &
            flwout      (i),                           &
            Sswabsn   (i,:,:), Iswabsn   (i,:,:), &
            flw         (i), coszen      (i), & 
            fsens       (i), fsensn      (i,:), &
            flat        (i), flatn       (i,:), &
            evap        (i),                           &
            fresh       (i), fsalt       (i), &
            fhocn       (i), fswthru     (i), &
            flatn_f     (i,:), fsensn_f    (i,:), &
            fsurfn_f    (i,:), fcondtopn_f (i,:), &
            faero_atm   (i,1:n_aero),                    &
            faero_ocn   (i,1:n_aero),                    &
            dhsn        (i,:), ffracn      (i,:), &
            meltt       (i), melttn      (i,:), &
            meltb       (i), meltbn      (i,:), &
            meltl       (i),                           &
            melts       (i), meltsn      (i,:), &
            congel      (i), congeln     (i,:), &
            snoice      (i), snoicen     (i,:), &
            dsnown      (i,:), frazil      (i), &
            lmask_n     (i), lmask_s     (i), &
            mlt_onset   (i), frz_onset   (i), &
            yday,                     l_stop,                   &
            stop_label,                                         &
            prescribed_ice)
        
        call icepack_print_warnings(nu_diag)
        
        if (l_stop) then
          call diagnostic_abort(i, istep1, stop_label)
        endif
        
        if (tr_aero) then
          do n = 1, ncat
            if (vicen(i,n) > puny) &
                aeroice(:,:,n) = aeroice(:,:,n)/vicen(i,n)
            if (vsnon(i,n) > puny) &
                aerosno(:,:,n) = aerosno(:,:,n)/vsnon(i,n)
            do k = 1, n_aero
              do kk = 1, 2
                trcrn(i,nt_aero+(k-1)*4+kk-1,n)=aerosno(k,kk,n)
                trcrn(i,nt_aero+(k-1)*4+kk+1,n)=aeroice(k,kk,n)
              enddo
            enddo
          enddo
        endif ! tr_aero
        
      enddo ! i
      
    end subroutine step_therm1

!=======================================================================
! Driver for thermodynamic changes not needed for coupling:
! transport in thickness space, lateral growth and melting.
!
! authors: William H. Lipscomb, LANL
!          Elizabeth C. Hunke, LANL

      subroutine step_therm2 (dt)

      use icepack_drv_arrays_column, only: hin_max, fzsal, ocean_bio, &
          first_ice, bgrid, cgrid, igrid
      use icepack_drv_calendar, only: istep1, yday
      use icepack_drv_diagnostics, only: diagnostic_abort
      use icepack_drv_domain_size, only: ncat, nilyr, nslyr, n_aero, nblyr, nltrcr, nx
      use icepack_drv_flux, only: fresh, frain, fpond, frzmlt, frazil, frz_onset, &
          update_ocn_f, fsalt, Tf, sss, salinz, fhocn, rside, &
          meltl, frazil_diag, flux_bio, faero_ocn 
      use icepack_drv_init, only: tmask
      use icepack_drv_state, only: aice, aicen, aice0, trcr_depend, &
          aicen_init, vicen_init, trcrn, vicen, vsnon, &
          trcr_base, n_trcr_strata, nt_strata

      ! column package_includes
      use icepack_intfc, only: icepack_step_therm2, &
          icepack_clear_warnings, icepack_print_warnings
      use icepack_intfc_tracers, only: ntrcr, nbtrcr

      real (kind=dbl_kind), intent(in) :: &
         dt      ! time step

      ! local variables

      integer (kind=int_kind) :: &
         i               ! horizontal indices

      logical (kind=log_kind) :: &
         l_stop          ! if true, abort model

      character (char_len) :: stop_label

      l_stop = .false.
      
      do i = 1, nx

         if (tmask(i)) then

         call icepack_clear_warnings()
            
         call icepack_step_therm2(dt, ncat, n_aero, nltrcr,                 &
                           nilyr,                  nslyr,                  &
                           hin_max   (:),          nblyr,                  &   
                           aicen     (i,:),                         &
                           vicen     (i,:), vsnon     (i,:), &
                           aicen_init(i,:), vicen_init(i,:), &
                           trcrn     (i,1:ntrcr,:),                 &
                           aice0     (i), aice      (i), &
                           trcr_depend(1:ntrcr),   trcr_base(1:ntrcr,:),   &
                           n_trcr_strata(1:ntrcr), nt_strata(1:ntrcr,:),   &
                           Tf        (i), sss       (i), &
                           salinz    (i,:),                         &
                           rside     (i), meltl     (i), &
                           frzmlt    (i), frazil    (i), &
                           frain     (i), fpond     (i), &
                           fresh     (i), fsalt     (i), &
                           fhocn     (i), update_ocn_f,           &
                           bgrid,                  cgrid,                  &
                           igrid,                  faero_ocn (i,:), &
                           first_ice (i,:), fzsal     (i), &
                           flux_bio  (i,1:nbtrcr),                  &
                           ocean_bio (i,1:nbtrcr),                  &
                           l_stop,                 stop_label,             &
                           frazil_diag(i),                         &
                           frz_onset (i), yday)

         call icepack_print_warnings(nu_diag)
         
         if (l_stop) call diagnostic_abort(i, istep1, stop_label)

         endif ! tmask

      enddo                     ! i
         
      end subroutine step_therm2

!=======================================================================
!
! finalize thermo updates
!
! authors: Elizabeth Hunke, LANL

      subroutine update_state (dt, daidt, dvidt, dagedt, offset)

      use icepack_drv_domain_size, only: ncat, nx
      use icepack_drv_init, only: tmask
      use icepack_drv_state, only: aicen, trcrn, vicen, vsnon, &
                           aice,  trcr,  vice,  vsno, aice0, trcr_depend, &
                           trcr_base, nt_strata, n_trcr_strata

      ! column package includes
      use icepack_intfc, only: icepack_aggregate
      use icepack_intfc_tracers, only: ntrcr, tr_iage, nt_iage

      real (kind=dbl_kind), intent(in) :: &
         dt    , & ! time step
         offset    ! d(age)/dt time offset = dt for thermo, 0 for dyn

      real (kind=dbl_kind), dimension(:), intent(inout) :: &
          daidt, & ! change in ice area per time step
          dvidt, & ! change in ice volume per time step
          dagedt   ! change in ice age per time step

      integer (kind=int_kind) :: & 
         i       ! horizontal indices

      !$OMP PARALLEL DO PRIVATE(i)
      do i = 1, nx

      !-----------------------------------------------------------------
      ! Aggregate the updated state variables (includes ghost cells). 
      !----------------------------------------------------------------- 
 
         if (tmask(i)) &
         call icepack_aggregate (ncat,               aicen(i,:),   &
                               trcrn(i,1:ntrcr,:),               &
                               vicen(i,:), vsnon(i,:),  &
                               aice (i),                       &
                               trcr (i,1:ntrcr),               &
                               vice (i), vsno (i),  &
                               aice0(i),                       &
                               ntrcr,                                   &
                               trcr_depend(1:ntrcr),                    &
                               trcr_base    (1:ntrcr,:),                &
                               n_trcr_strata(1:ntrcr),                  &
                               nt_strata    (1:ntrcr,:))

      !-----------------------------------------------------------------
      ! Compute thermodynamic area and volume tendencies.
      !-----------------------------------------------------------------

         daidt(i) = (aice(i) - daidt(i)) / dt
         dvidt(i) = (vice(i) - dvidt(i)) / dt
         if (tr_iage) then
            if (offset > c0) then                 ! thermo
               if (trcr(i,nt_iage) > c0) &
               dagedt(i) = (trcr(i,nt_iage) &
                                - dagedt(i) - offset) / dt
            else                                  ! dynamics
               dagedt(i) = (trcr(i,nt_iage) &
                                - dagedt(i)) / dt
            endif
         endif

      enddo ! i
      !$OMP END PARALLEL DO

      end subroutine update_state

!=======================================================================
!
! Run one time step of ridging.
!
! authors: William H. Lipscomb, LANL
!          Elizabeth C. Hunke, LANL

      subroutine step_dyn_ridge (dt, ndtd)

      use icepack_drv_arrays_column, only: hin_max, fzsal, first_ice
      use icepack_drv_calendar, only: istep1
      use icepack_drv_diagnostics, only: diagnostic_abort
      use icepack_drv_domain_size, only: ncat, nilyr, nslyr, n_aero, nblyr, nx
      use icepack_drv_flux, only: &
          rdg_conv, rdg_shear, dardg1dt, dardg2dt, &
          dvirdgdt, opening, fpond, fresh, fhocn, &
          aparticn, krdgn, aredistn, vredistn, dardg1ndt, dardg2ndt, &
          dvirdgndt, araftn, vraftn, fsalt, flux_bio, faero_ocn
      use icepack_drv_init, only: tmask
      use icepack_drv_state, only: trcrn, vsnon, aicen, vicen, &
          aice, trcr, vice, vsno, aice0, trcr_depend, n_trcr_strata, &
          trcr_base, nt_strata

      ! column package includes
      use icepack_intfc, only: icepack_step_ridge, &
          icepack_clear_warnings, icepack_print_warnings
      use icepack_intfc_tracers, only: ntrcr, nbtrcr

      real (kind=dbl_kind), intent(in) :: &
         dt      ! time step

      integer (kind=int_kind), intent(in) :: &
         ndtd    ! number of dynamics subcycles

      ! local variables

      integer (kind=int_kind) :: & 
         i               ! horizontal indices

      logical (kind=log_kind) :: &
         l_stop          ! if true, abort the model

      character (char_len) :: stop_label

      !-----------------------------------------------------------------
      ! Ridging
      !-----------------------------------------------------------------

         do i = 1, nx

!echmod: this changes the answers, continue using tmask for now
!      call aggregate_area (ncat, aicen(:), atmp, atmp0)
!      if (atmp > c0) then

         if (tmask(i)) then

         call icepack_clear_warnings()
               
         call icepack_step_ridge (dt,            ndtd,                  &
                         nilyr,                 nslyr,                 &
                         nblyr,                                        &
                         ncat,                  hin_max  (:),          &
                         rdg_conv (i), rdg_shear(i), &
                         aicen    (i,:),                        &
                         trcrn    (i,1:ntrcr,:),                &
                         vicen    (i,:), vsnon    (i,:), &
                         aice0    (i), trcr_depend(1:ntrcr),  &
                         trcr_base(1:ntrcr,:),  n_trcr_strata(1:ntrcr),&
                         nt_strata(1:ntrcr,:),                         &
                         dardg1dt (i), dardg2dt (i), &
                         dvirdgdt (i), opening  (i), &
                         fpond    (i),                        &
                         fresh    (i), fhocn    (i), &
                         n_aero,                                       &
                         faero_ocn(i,:),                        &
                         aparticn (i,:), krdgn    (i,:), &
                         aredistn (i,:), vredistn (i,:), &
                         dardg1ndt(i,:), dardg2ndt(i,:), &
                         dvirdgndt(i,:),                        &
                         araftn   (i,:), vraftn   (i,:), &
                         aice     (i), fsalt    (i), &
                         first_ice(i,:), fzsal    (i), &
                         flux_bio (i,1:nbtrcr),                 &
                         l_stop,                stop_label)

         call icepack_print_warnings(nu_diag)
         
         if (l_stop) call diagnostic_abort(i, istep1, stop_label)
         endif ! tmask

         enddo ! i

      end subroutine step_dyn_ridge

!=======================================================================
!
! Computes radiation fields
!
! authors: William H. Lipscomb, LANL
!          David Bailey, NCAR
!          Elizabeth C. Hunke, LANL

      subroutine step_radiation (dt)

      use icepack_drv_arrays_column, only: ffracn, dhsn, &
          fswsfcn, fswintn, fswthrun, fswpenln, Sswabsn, Iswabsn, &
          albicen, albsnon, albpndn, &
          alvdrn, alidrn, alvdfn, alidfn, apeffn, trcrn_sw, snowfracn, &
          kaer_tab, waer_tab, gaer_tab, kaer_bc_tab, waer_bc_tab, &
          gaer_bc_tab, bcenh, swgrid, igrid
      use icepack_drv_calendar, only: calendar_type, days_per_year, nextsw_cday, yday, sec
      use icepack_drv_domain_size, only: ncat, n_aero, nilyr, nslyr, n_zaero, n_algae, nblyr, nx
      use icepack_drv_flux, only: swvdr, swvdf, swidr, swidf, coszen, fsnow
      use icepack_drv_init, only: TLAT, TLON, tmask
      use icepack_drv_state, only: aicen, vicen, vsnon, trcrn

      ! column package includes
      use icepack_intfc, only: icepack_step_radiation, &
          icepack_clear_warnings, icepack_print_warnings
      use icepack_intfc_tracers, only: nt_Tsfc, nt_alvl, tr_bgc_N, &
          nt_apnd, nt_hpnd, nt_ipnd, nt_aero, nlt_chl_sw, nlt_zaero_sw, &
          tr_zaero, ntrcr, nbtrcr, nbtrcr_sw, nt_fbri, tr_brine, nt_zaero
      use icepack_intfc_shared, only: dEdd_algae, modal_aero

      real (kind=dbl_kind), intent(in) :: &
         dt                 ! time step

      ! local variables

      integer (kind=int_kind) :: &
         i, n,   k,    & ! horizontal indices
         ipoint             ! index for print diagnostic

      real (kind=dbl_kind), dimension(ncat) :: &
         fbri                 ! brine height to ice thickness

      real(kind= dbl_kind), dimension(ntrcr, ncat) :: &
         ztrcr

      real(kind= dbl_kind), dimension(ntrcr, ncat) :: &
         ztrcr_sw

      logical (kind=log_kind) :: &
         l_print_point      ! flag for printing debugging information

      l_print_point = .false.

      do i = 1, nx

         fbri(:) = c0
         ztrcr_sw(:,:) = c0
         do n = 1, ncat
           do k = 1, ntrcr
             ztrcr(k,n) = trcrn(i,k,n)
           enddo
           if (tr_brine)  fbri(n) = trcrn(i,nt_fbri,n)
         enddo

         if (tmask(i)) then

         call icepack_clear_warnings()
            
         call icepack_step_radiation (dt,         ncat,                    &
                          n_algae,   tr_zaero, nblyr,                     &
                          ntrcr,     nbtrcr,   nbtrcr_sw,                 &
                          nilyr,    nslyr,       n_aero,                  &
                          n_zaero,  dEdd_algae,  nlt_chl_sw,              &
                          nlt_zaero_sw(:),                                &
                          swgrid(:),           igrid(:),                  &
                          fbri(:),                                        &
                          aicen(i,:),     vicen(i,:),       &
                          vsnon(i,:),                              &
                          trcrn(i,nt_Tsfc,:),                      &
                          trcrn(i,nt_alvl,:),                      &
                          trcrn(i,nt_apnd,:),                      &
                          trcrn(i,nt_hpnd,:),                      &
                          trcrn(i,nt_ipnd,:),                      &
                          trcrn(i,nt_aero:nt_aero+4*n_aero-1,:),   &
                          ztrcr_sw,                                       &
                          ztrcr,                                          &
                          TLAT(i),        TLON(i),          &
                          calendar_type,         days_per_year,           &
                          nextsw_cday,           yday,                    &
                          sec,                                            &
                          kaer_tab, waer_tab,                             &
                          gaer_tab,                                       &
                          kaer_bc_tab(:,:),      waer_bc_tab(:,:),        &
                          gaer_bc_tab(:,:),      bcenh(:,:,:),            &
                          modal_aero,                                     &
                          swvdr(i),       swvdf(i),         &
                          swidr(i),       swidf(i),         &
                          coszen(i),      fsnow(i),         &
                          alvdrn(i,:),    alvdfn(i,:),      &
                          alidrn(i,:),    alidfn(i,:),      &
                          fswsfcn(i,:),   fswintn(i,:),     &
                          fswthrun(i,:),  fswpenln(i,:,:),  &
                          Sswabsn(i,:,:), Iswabsn(i,:,:),   &
                          albicen(i,:),   albsnon(i,:),     &
                          albpndn(i,:),   apeffn(i,:),      &
                          snowfracn(i,:),                          &
                          dhsn(i,:),      ffracn(i,:),      &
                          l_print_point)

         call icepack_print_warnings(nu_diag)

         endif ! tmask

      if (dEdd_algae .and. (tr_zaero .or. tr_bgc_N)) then
        do n = 1, ncat
           do k = 1, nbtrcr_sw
              trcrn_sw(i,k,n) = ztrcr_sw(k,n)
           enddo
        enddo
      endif

      enddo ! i

      end subroutine step_radiation

!=======================================================================
! Ocean mixed layer calculation (internal to sea ice model).
! Allows heat storage in ocean for uncoupled runs.
!
! authors:   John Weatherly, CRREL
!            C.M. Bitz, UW
!            Elizabeth C. Hunke, LANL
!            Bruce P. Briegleb, NCAR
!            William H. Lipscomb, LANL

      subroutine ocean_mixed_layer (dt)

      use icepack_drv_arrays_column, only: Cdn_atm, Cdn_atm_ratio
      use icepack_constants, only: c0, c1000, albocn
      use icepack_intfc, only: icepack_ocn_mixed_layer, icepack_atm_boundary
      use icepack_drv_domain_size, only: nx
      use icepack_drv_flux, only: sst, Tf, Qa, uatm, vatm, wind, potT, rhoa, zlvl, &
           frzmlt, fhocn, fswthru, flw, flwout_ocn, fsens_ocn, flat_ocn, evap_ocn, &
           alvdr_ocn, alidr_ocn, alvdf_ocn, alidf_ocn, swidf, swvdf, swidr, swvdr, &
           qdp, hmix, strairx_ocn, strairy_ocn, Tref_ocn, Qref_ocn
      use icepack_drv_state, only: aice

      real (kind=dbl_kind), intent(in) :: &
         dt      ! time step

      ! local variables

      real (kind=dbl_kind) :: &
         TsfK , & ! surface temperature (K)
         swabs    ! surface absorbed shortwave heat flux (W/m^2)

      real (kind=dbl_kind), parameter :: &
         frzmlt_max = c1000   ! max magnitude of frzmlt (W/m^2)

      integer (kind=int_kind) :: &
         i           , & ! horizontal indices
         ij                 ! combined ij index

      real (kind=dbl_kind), dimension(nx) :: &
         delt  , & ! potential temperature difference   (K)
         delq  , & ! specific humidity difference   (kg/kg)
         shcoef, & ! transfer coefficient for sensible heat
         lhcoef    ! transfer coefficient for latent heat

      !-----------------------------------------------------------------
      ! Identify ocean cells.
      ! Set fluxes to zero in land cells.
      !-----------------------------------------------------------------

         do i = 1, nx
               sst       (i) = c0
               frzmlt    (i) = c0
               flwout_ocn(i) = c0
               fsens_ocn (i) = c0
               flat_ocn  (i) = c0
               evap_ocn  (i) = c0
         enddo                  ! i

      !-----------------------------------------------------------------
      ! Compute boundary layer quantities
      !-----------------------------------------------------------------

            do i = 1, nx

               call icepack_atm_boundary( 'ocn',                &
                                        sst        (i), &    
                                        potT       (i), &
                                        uatm       (i), &   
                                        vatm       (i), &   
                                        wind       (i), &   
                                        zlvl       (i), &   
                                        Qa         (i), &     
                                        rhoa       (i), &
                                        strairx_ocn(i), & 
                                        strairy_ocn(i), & 
                                        Tref_ocn   (i), & 
                                        Qref_ocn   (i), & 
                                        delt       (i),      &    
                                        delq       (i),      &
                                        lhcoef     (i),      &
                                        shcoef     (i),      &
                                        Cdn_atm    (i), & 
                                        Cdn_atm_ratio(i))    
            enddo ! i

      !-----------------------------------------------------------------
      ! Ocean albedo
      ! For now, assume albedo = albocn in each spectral band.
      !-----------------------------------------------------------------

         alvdr_ocn(:) = albocn
         alidr_ocn(:) = albocn
         alvdf_ocn(:) = albocn
         alidf_ocn(:) = albocn

      !-----------------------------------------------------------------
      ! Compute ocean fluxes and update SST
      !-----------------------------------------------------------------
      do i = 1, nx

         call icepack_ocn_mixed_layer (alvdr_ocn(i), swvdr     (i), &
                                      alidr_ocn(i), swidr     (i), &
                                      alvdf_ocn(i), swvdf     (i), &
                                      alidf_ocn(i), swidf     (i), &
                                      sst      (i), flwout_ocn(i), &
                                      fsens_ocn(i), shcoef    (i),      &
                                      flat_ocn (i), lhcoef    (i),      &
                                      evap_ocn (i), flw       (i), &
                                      delt     (i),      delq      (i),      &
                                      aice     (i), fhocn     (i), &
                                      fswthru  (i), hmix      (i), &
                                      Tf       (i), qdp       (i), &
                                      frzmlt   (i), dt)
      enddo                    ! i

      end subroutine ocean_mixed_layer

!=======================================================================

      subroutine biogeochemistry (dt)

      use icepack_drv_arrays_column, only: upNO, upNH, iDi, iki, zfswin, &
                           trcrn_sw, zsal_tot, darcy_V, grow_net,  &
                           PP_net, hbri,dhbr_bot, dhbr_top, Zoo,&
                           fbio_snoice, fbio_atmice, ocean_bio,  &
                           first_ice, fswpenln, bphi, bTiz, ice_bio_net,  &
                           snow_bio_net, fswthrun, Rayleigh_criteria, &
                           ocean_bio_all, sice_rho, fzsal, fzsal_g, &
                           bgrid, igrid, icgrid, cgrid
      use icepack_drv_calendar, only: istep1
      use icepack_intfc, only: icepack_biogeochemistry, icepack_init_OceanConcArray, &
          icepack_clear_warnings, icepack_print_warnings
      use icepack_intfc_shared, only: skl_bgc, max_algae, max_nbtrcr, max_don, &
                             max_doc, max_dic, max_aero, max_fe
      use icepack_intfc_tracers, only: tr_brine, nbtrcr, ntrcr, bio_index_o, nlt_zaero, tr_zaero
      use icepack_drv_diagnostics, only: diagnostic_abort
      use icepack_drv_domain_size, only: nblyr, nilyr, nslyr, n_algae, n_zaero, ncat, &
                                 n_doc, n_dic,  n_don, n_fed, n_fep, nx
      use icepack_drv_flux, only: meltbn, melttn, congeln, snoicen, &
                          sst, sss, fsnow, meltsn, hmix, salinz, &
                          hin_old, flux_bio, flux_bio_atm, faero_atm, & 
          nit, amm, sil, dmsp, dms, algalN, doc, don, dic, fed, fep, zaeros, hum
      use icepack_drv_state, only: aicen_init, vicen_init, aicen, vicen, vsnon, &
          trcrn, vsnon_init, aice0                    

      real (kind=dbl_kind), intent(in) :: &
         dt      ! time step

      ! local variables

      integer (kind=int_kind) :: &
         i           , & ! horizontal indices
         k              , & ! vertical index
         n, mm              ! tracer index

      logical (kind=log_kind) :: &
         l_stop          ! if true, abort the model

      character (char_len) :: stop_label

      if (tr_brine .or. skl_bgc) then

      ! Define ocean concentrations for tracers used in simulation
      do i = 1, nx

         call icepack_init_OceanConcArray(max_nbtrcr, &
                max_algae, max_don,  max_doc,        &
                max_dic,   max_aero, max_fe,         &
                nit(i), amm   (i), &
                sil(i), dmsp  (i), &
                dms(i), algalN(i,:), &
                doc(i,:), don   (i,:), &
                dic(i,:), fed   (i,:), &
                fep(i,:), zaeros(i,:), &
                ocean_bio_all(i,:), &
                hum(i))
        
         do mm = 1,nbtrcr
            ocean_bio(i,mm) = ocean_bio_all(i,bio_index_o(mm))  
         enddo  ! mm    
         if (tr_zaero) then
            do mm = 1, n_zaero  ! update aerosols
               flux_bio_atm(i,nlt_zaero(mm)) = faero_atm(i,mm)
            enddo  ! mm
         endif

         call icepack_clear_warnings()
         
         call icepack_biogeochemistry(dt, ntrcr, nbtrcr,&
                              upNO        (i),        &
                              upNH        (i),        &
                              iDi         (i,:,:),        &
                              iki         (i,:,:),        &
                              zfswin      (i,:,:),        &
                              zsal_tot    (i),        &
                              darcy_V     (i,:),        &
                              grow_net    (i),        &
                              PP_net      (i),        &
                              hbri        (i),        &
                              dhbr_bot    (i,:),        &
                              dhbr_top    (i,:),        &
                              Zoo         (i,:,:),        &
                              fbio_snoice (i,:),        &
                              fbio_atmice (i,:),        &
                              ocean_bio   (i,1:nbtrcr),        &
                              first_ice   (i,:),        &
                              fswpenln    (i,:,:),        &
                              bphi        (i,:,:),        &
                              bTiz        (i,:,:),        &
                              ice_bio_net (i,1:nbtrcr),        &
                              snow_bio_net(i,1:nbtrcr),        &
                              fswthrun    (i,:),        &
                              Rayleigh_criteria(i),        &
                              sice_rho    (i,:),        &
                              fzsal       (i),        &   
                              fzsal_g     (i),        &
                              bgrid, igrid, icgrid, cgrid,     &
                              nblyr, nilyr, nslyr, n_algae, n_zaero,   &
                              ncat, n_doc, n_dic, n_don, n_fed, n_fep, &
                              meltbn      (i,:),        &
                              melttn      (i,:),        &
                              congeln     (i,:),        &
                              snoicen     (i,:),        & 
                              sst         (i),        &    
                              sss         (i),        &
                              fsnow       (i),        &
                              meltsn      (i,:),        &
                              hmix        (i),        &
                              salinz      (i,1:nilyr),        &
                              hin_old     (i,:),        &
                              flux_bio    (i,1:nbtrcr),        &
                              flux_bio_atm(i,1:nbtrcr),        &
                              aicen_init  (i,:),        &
                              vicen_init  (i,:),        &
                              aicen       (i,:),        &
                              vicen       (i,:),        &
                              vsnon       (i,:),        &
                              aice0       (i),        &
                              trcrn       (i,1:ntrcr,:),        &
                              vsnon_init  (i,:),        &
                              skl_bgc, max_algae, max_nbtrcr,          &
                              l_stop, stop_label)

         call icepack_print_warnings(nu_diag)
         
         if (l_stop) call diagnostic_abort(i, istep1, stop_label)

      enddo               ! i

      endif  ! tr_brine .or. skl_bgc

      end subroutine biogeochemistry

!=======================================================================

      end module icepack_drv_step_mod

!=======================================================================
