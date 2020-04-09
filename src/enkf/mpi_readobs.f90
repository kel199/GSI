module mpi_readobs
!$$$  module documentation block
!
! module: mpi_readobs                  read obs, ob priors and associated
!                                      metadata if called from root task, 
!                                      otherwise receive data from root task.
!
! prgmmr: whitaker         org: esrl/psd               date: 2009-02-23
!
! abstract:
!
! Public Subroutines:
!  mpi_readobs: called by subroutine readobs in module enkf_obsmod. 
!   Read obs, ob priors and metadata from diag* files
!   created by GSI forward operator code and broadcast to all tasks.
!   
! Public Variables: None
!
! Modules Used:
!  readsatobs: to read satellite radiance diag* files.
!  readconvobs: to read diag_conv* files (obs from prepbufr file).
!  readozobs: to read diag_sbuv* ozone files.
!  mpisetup
!
! program history log:
!   2009-02-23  Initial version.
!   2016-11-29  shlyaeva: Added the option of writing out ensemble spread in
!               diag files
!
! attributes:
!   language: f95
!
!$$$
  
use kinds, only: r_kind, r_single, i_kind, r_double
use params, only: ntasks_io, nanals_per_iotask, nanal1, nanal2
use radinfo, only: npred
use readconvobs
use readsatobs
use readozobs
use mpimod, only: mpi_comm_world
use mpisetup, only: mpi_real4,mpi_sum,mpi_comm_io,mpi_in_place,numproc,nproc,&
                mpi_integer,mpi_wtime,mpi_status,mpi_real8,mpi_max,mpi_realkind,&
                mpi_min,numproc_shm,mpi_comm_shmem,mpi_info_null,nproc_shm,&
                mpi_comm_shmemroot,mpi_mode_nocheck,mpi_lock_exclusive,&
                mpi_address_kind
use, intrinsic :: iso_c_binding
use kinds, only: r_double,i_kind,r_kind,r_single,num_bytes_for_r_single

implicit none

private
public :: mpi_getobs

contains

subroutine mpi_getobs(obspath, datestring, nobs_conv, nobs_oz, nobs_sat, nobs_tot, &
                      nobs_convdiag, nobs_ozdiag, nobs_satdiag, nobs_totdiag, &
                      sprd_ob, ensmean_ob, ob, &
                      oberr, oblon, oblat, obpress, &
                      obtime, oberrorig, obcode, obtype, &
                      diagused,  anal_ob, anal_ob_modens, anal_ob_cp, anal_ob_modens_cp, &
                      shm_win, shm_win2, indxsat, nanals, neigv)
    character*500, intent(in) :: obspath
    character*10, intent(in) :: datestring
    character(len=10) :: id
    real(r_single), allocatable, dimension(:)   :: ensmean_ob,ob,oberr,oblon,oblat
    real(r_single), allocatable, dimension(:)   :: obpress,obtime,oberrorig,sprd_ob
    integer(i_kind), allocatable, dimension(:)  :: obcode,indxsat
    integer(i_kind), allocatable, dimension(:)  :: diagused
    ! pointers used for MPI-3 shared memory manipulations.
    real(r_single), pointer, dimension(:,:)     :: anal_ob, anal_ob_modens
    type(c_ptr) anal_ob_cp, anal_ob_modens_cp
    integer shm_win, shm_win2
    real(r_single), allocatable, dimension(:)   :: mem_ob
    real(r_single), allocatable, dimension(:,:) :: mem_ob_modens
    real(r_single) :: analsim1
    real(r_double) t1,t2
    character(len=20), allocatable,  dimension(:) ::  obtype
    integer(i_kind) nob, ierr, iozproc, isatproc, neig, nens1, nens2, na, nmem,&
            np, nobs_conv, nobs_oz, nobs_sat, nobs_tot, nanal, nanalo, nens
    integer(i_kind) :: nobs_convdiag, nobs_ozdiag, nobs_satdiag, nobs_totdiag
    integer(i_kind), intent(in) :: nanals, neigv

    integer disp_unit
    integer(MPI_ADDRESS_KIND) :: win_size, nsize, nsize2, win_size2
    integer(MPI_ADDRESS_KIND) :: segment_size

    iozproc=max(0,min(1,numproc-1))
    isatproc=max(0,min(2,numproc-2))
! get total number of conventional and sat obs for ensmean.
    id = 'ensmean'
    if(nproc == 0)call get_num_convobs(obspath,datestring,nobs_conv,nobs_convdiag,id)
    if(nproc == iozproc)call get_num_ozobs(obspath,datestring,nobs_oz,nobs_ozdiag,id)
    if(nproc == isatproc)call get_num_satobs(obspath,datestring,nobs_sat,nobs_satdiag,id)
    call mpi_bcast(nobs_conv,1,mpi_integer,0,mpi_comm_world,ierr)
    call mpi_bcast(nobs_convdiag,1,mpi_integer,0,mpi_comm_world,ierr)
    call mpi_bcast(nobs_oz,1,mpi_integer,iozproc,mpi_comm_world,ierr)
    call mpi_bcast(nobs_ozdiag,1,mpi_integer,iozproc,mpi_comm_world,ierr)
    call mpi_bcast(nobs_sat,1,mpi_integer,isatproc,mpi_comm_world,ierr)
    call mpi_bcast(nobs_satdiag,1,mpi_integer,isatproc,mpi_comm_world,ierr)
    if(nproc == 0)print *,'nobs_conv, nobs_oz, nobs_sat = ',nobs_conv,nobs_oz,nobs_sat
    if(nproc == 0)print *,'total diag nobs_conv, nobs_oz, nobs_sat = ', nobs_convdiag, nobs_ozdiag, nobs_satdiag
    nobs_tot = nobs_conv + nobs_oz + nobs_sat
    nobs_totdiag = nobs_convdiag + nobs_ozdiag + nobs_satdiag
    if (neigv > 0) then
       nens = nanals*neigv ! modulated ensemble size
    else
       nens = nanals
    endif
! if nobs_tot != 0 (there were some obs to read)
    if (nobs_tot > 0) then
       ! these arrays needed on all processors.
       allocate(mem_ob(nobs_tot)) 
       allocate(mem_ob_modens(neigv,nobs_tot))  ! zero size if neigv=0
       allocate(sprd_ob(nobs_tot),ob(nobs_tot),oberr(nobs_tot),oblon(nobs_tot),&
       oblat(nobs_tot),obpress(nobs_tot),obtime(nobs_tot),oberrorig(nobs_tot),obcode(nobs_tot),&
       obtype(nobs_tot),ensmean_ob(nobs_tot),&
       indxsat(nobs_sat), diagused(nobs_totdiag))
    else
! stop if no obs found (must be an error somewhere).
       print *,'no obs found!'
       call stop2(11)
    end if

! setup shared memory segment on each node that points to
! observation prior ensemble.
! shared window size will be zero except on root task of
! shared memory group on each node.
    disp_unit = num_bytes_for_r_single ! anal_ob is r_single
    nsize = nobs_tot*nanals
    nsize2 = nobs_tot*nanals*neigv
    if (nproc_shm == 0) then
       win_size = nsize*disp_unit
       win_size2 = nsize2*disp_unit
    else
       win_size = 0
       win_size2 = 0
    endif
    call MPI_Win_allocate_shared(win_size, disp_unit, MPI_INFO_NULL,&
                                 mpi_comm_shmem, anal_ob_cp, shm_win, ierr)
    if (neigv > 0) then
       call MPI_Win_allocate_shared(win_size2, disp_unit, MPI_INFO_NULL,&
                                    mpi_comm_shmem, anal_ob_modens_cp, shm_win2, ierr)
    endif
    ! associate fortran pointer with c pointer to shared memory 
    ! segment (containing observation prior ensemble) on each task.
    call MPI_Win_shared_query(shm_win, 0, segment_size, disp_unit, anal_ob_cp, ierr)
    call c_f_pointer(anal_ob_cp, anal_ob, [nanals, nobs_tot])
    call MPI_Win_fence(0, shm_win, ierr)
    anal_ob=0
    call MPI_Win_fence(0, shm_win, ierr)
    if (neigv > 0) then
       call MPI_Win_shared_query(shm_win2, 0, segment_size, disp_unit, anal_ob_modens_cp, ierr)
       call c_f_pointer(anal_ob_modens_cp, anal_ob_modens, [nens, nobs_tot])
       call MPI_Win_fence(0, shm_win2, ierr)
       anal_ob_modens=0
       call MPI_Win_fence(0, shm_win2, ierr)
    endif
  

! read ensemble mean and every ensemble member
    if (nproc <= ntasks_io-1) then
        nens1 = nanal1(nproc); nens2 = nanal2(nproc)
    else
        nens1 = nanals+1; nens2 = nanals+1
    endif

    id = 'ensmean'

    nmem = 0
    do nanal=nens1,nens2 ! loop over ens members on this task
    nmem = nmem + 1 
! read obs.
! only thing that is different on each task is mem_ob.  All other
! fields are defined from ensemble mean.
! individual members read on 1st nanals tasks, ens mean read on all tasks.
    if (nobs_conv > 0) then
! first nobs_conv are conventional obs.
      call get_convobs_data(obspath, datestring, nobs_conv, nobs_convdiag, &
        ensmean_ob(1:nobs_conv),                                           &
        mem_ob(1:nobs_conv), mem_ob_modens(1:neigv,1:nobs_conv),           &
        ob(1:nobs_conv),                                                   &
        oberr(1:nobs_conv), oblon(1:nobs_conv), oblat(1:nobs_conv),        &
        obpress(1:nobs_conv), obtime(1:nobs_conv), obcode(1:nobs_conv),    &
        oberrorig(1:nobs_conv), obtype(1:nobs_conv),                       &
        diagused(1:nobs_convdiag), id, nanal, nmem)
    end if
    if (nobs_oz > 0) then
! second nobs_oz are conventional obs.
      call get_ozobs_data(obspath, datestring, nobs_oz, nobs_ozdiag,  &
        ensmean_ob(nobs_conv+1:nobs_conv+nobs_oz),                    &
        mem_ob(nobs_conv+1:nobs_conv+nobs_oz),                        &
        mem_ob_modens(1:neigv,nobs_conv+1:nobs_conv+nobs_oz),         &
        ob(nobs_conv+1:nobs_conv+nobs_oz),               &
        oberr(nobs_conv+1:nobs_conv+nobs_oz),            &
        oblon(nobs_conv+1:nobs_conv+nobs_oz),            &
        oblat(nobs_conv+1:nobs_conv+nobs_oz),            &
        obpress(nobs_conv+1:nobs_conv+nobs_oz),          &
        obtime(nobs_conv+1:nobs_conv+nobs_oz),           &
        obcode(nobs_conv+1:nobs_conv+nobs_oz),           &
        oberrorig(nobs_conv+1:nobs_conv+nobs_oz),        &
        obtype(nobs_conv+1:nobs_conv+nobs_oz),           &
        diagused(nobs_convdiag+1:nobs_convdiag+nobs_ozdiag),&
        id,nanal,nmem)
    end if
    if (nobs_sat > 0) then
! last nobs_sat are satellite radiance obs.
      call get_satobs_data(obspath, datestring, nobs_sat, nobs_satdiag, &
        ensmean_ob(nobs_conv+nobs_oz+1:nobs_tot),         &
        mem_ob(nobs_conv+nobs_oz+1:nobs_tot),                &
        mem_ob_modens(1:neigv,nobs_conv+nobs_oz+1:nobs_tot),            &
        ob(nobs_conv+nobs_oz+1:nobs_tot),                 &
        oberr(nobs_conv+nobs_oz+1:nobs_tot),              &
        oblon(nobs_conv+nobs_oz+1:nobs_tot),              &
        oblat(nobs_conv+nobs_oz+1:nobs_tot),              &
        obpress(nobs_conv+nobs_oz+1:nobs_tot),            &
        obtime(nobs_conv+nobs_oz+1:nobs_tot),             &
        obcode(nobs_conv+nobs_oz+1:nobs_tot),             &
        oberrorig(nobs_conv+nobs_oz+1:nobs_tot),          &
        obtype(nobs_conv+nobs_oz+1:nobs_tot),indxsat,     &
        diagused(nobs_convdiag+nobs_ozdiag+1:nobs_totdiag),&
        id,nanal,nmem)
    end if ! read obs.

!   ! populate obs prior ensemble shared array pointer on each io task.
    if (nproc <= ntasks_io-1) then
       call MPI_Win_fence(0, shm_win, ierr)
       anal_ob(nmem+nproc*nanals_per_iotask,:) = mem_ob(:)
       call MPI_Win_fence(0, shm_win, ierr)
       !print *,nproc,'filled anal_ob ens member',nmem+nproc*nanals_per_iotask
       if (neigv > 0) then
          na = nmem+nproc*nanals_per_iotask
          call MPI_Win_fence(0, shm_win2, ierr)
          anal_ob_modens(neigv*(na-1)+1:neigv*na,:) = mem_ob_modens(:,:)
          call MPI_Win_fence(0, shm_win2, ierr)
          !print *,nproc,'filled anal_ob_modens ens members',neigv*(na-1)+1,'to',neigv*na
       endif
    endif

    enddo ! nanal loop (loop over ens members on each task)
! wait here for all tasks before trying to run mpi_allreduce
    call mpi_barrier(mpi_comm_world, ierr)

! obs prior ensemble now defined on root task, bcast to other tasks.
    if (nproc == 0) print *,'broadcast ob prior ensemble perturbations'
    if (nproc == 0) t1 = mpi_wtime()
! exchange obs prior ensemble members across all tasks to fully populate shared
! memory array pointer on each node.
    if (nproc_shm == 0) then
       call mpi_allreduce(mpi_in_place,anal_ob,nanals*nobs_tot,mpi_real4,mpi_sum,mpi_comm_shmemroot,ierr)
       if (neigv > 0) then
          mem_ob_modens = 0.
          do na=1,nanals
             mem_ob_modens(:,:) = anal_ob_modens(neigv*(na-1)+1:neigv*na,:)
             call mpi_allreduce(mpi_in_place,mem_ob_modens,neigv*nobs_tot,mpi_real4,mpi_sum,mpi_comm_shmemroot,ierr)
             anal_ob_modens(neigv*(na-1)+1:neigv*na,:) = mem_ob_modens(:,:)
          enddo
       endif
    endif
    if (nproc == 0) then
        t2 = mpi_wtime()
        print *,'time to broadcast ob prior ensemble perturbations = ',t2-t1
    endif

    if (allocated(mem_ob)) deallocate(mem_ob)
    if (allocated(mem_ob_modens)) deallocate(mem_ob_modens)

! compute spread
    analsim1=1._r_single/float(nanals-1)
!$omp parallel do private(nob)
    do nob=1,nobs_tot
       sprd_ob(nob) = sum(anal_ob(:,nob)**2)*analsim1
    enddo
!$omp end parallel do
    if (neigv > 0) then
!$omp parallel do private(nob)
       do nob=1,nobs_tot
          sprd_ob(nob) = sum(anal_ob_modens(:,nob)**2)*analsim1
       enddo
!$omp end parallel do
    endif
    if (nproc == 0) then
       print *, 'prior spread conv: ', minval(sprd_ob(1:nobs_conv)), maxval(sprd_ob(1:nobs_conv))
       print *, 'prior spread oz: ', minval(sprd_ob(nobs_conv+1:nobs_conv+nobs_oz)), &
                                     maxval(sprd_ob(nobs_conv+1:nobs_conv+nobs_oz))
       print *, 'prior spread sat: ',minval(sprd_ob(nobs_conv+nobs_oz+1:nobs_tot)), &
                                     maxval(sprd_ob(nobs_conv+nobs_oz+1:nobs_tot))
       do nob =nobs_conv+nobs_oz+1 , nobs_tot
          if (sprd_ob(nob) > 1000.) then 
             print *, nob, ' sat spread: ', sprd_ob(nob), ', ensmean_ob: ', ensmean_ob(nob), &
                           ', anal_ob: ', anal_ob(:,nob), ', mem_ob: ', mem_ob(nob)
          endif
       enddo
    endif

 end subroutine mpi_getobs

end module mpi_readobs
