
	.extern _tpl_run_elected


; could be generated by goil? =>
TPL_KERN_OFFSET_S_RUNNING .equ 0
TPL_KERN_OFFSET_S_ELECTED .equ 4
TPL_KERN_OFFSET_RUNNING .equ 8
TPL_KERN_OFFSET_ELECTED .equ 12
TPL_KERN_OFFSET_RUNNING_ID .equ 16
TPL_KERN_OFFSET_ELECTED_ID .equ 20
TPL_KERN_OFFSET_NEED_SWITCH .equ 24
TPL_KERN_OFFSET_NEED_SCHEDULE .equ 25
SYSCALL_COUNT .equ 24

NO_NEED_SWITCH_NOR_SCHEDULE	.equ 0
NO_NEED_SWITCH	            .equ 0
NEED_SCHEDULE	            .equ 1
NEED_SWITCH	                .equ 1
NEED_SAVE	                .equ 2

; <=

KERNEL_STACK_SIZE	        .equ 200

	.section .data, data
	.align 4
_tpl_reentrancy_counter:
	.ds (4)

_tpl_kernel_stack:
	.rept KERNEL_STACK_SIZE-4
	.dw 0xDEADBEEF
	.endm

    .public _tpl_kernel_stack_bottom
_tpl_kernel_stack_bottom:
	.dw 0x00000000

	.section	"syscall.text", text
	.align	4
	;.align	512
	.public	__tpl_sc_handler
	.public	__tpl_syscall_table

__tpl_syscall_table:
	.rept SYSCALL_COUNT
	.dw #__tpl_sc_handler-#__tpl_syscall_table ; SYSCALLn
	.endm

 ; +------------------+
 ; | R31              | <- SP
 ; +------------------+
 ; | R30              | <- SP+4
 ; +------------------+
 ; | R29              | <- SP+8
 ; +------------------+
 ; | R28              | <- SP+12
 ; +------------------+
 ; | R27              | <- SP+16
 ; +------------------+
 ; | R26              | <- SP+20
 ; +------------------+
 ; | R25              | <- SP+24
 ; +------------------+
 ; | R24              | <- SP+28
 ; +------------------+
 ; | R23              | <- SP+32
 ; +------------------+
 ; | R22              | <- SP+36
 ; +------------------+
 ; | R21              | <- SP+40
 ; +------------------+
 ; | eipc             | <- SP+44
 ; +------------------+
 ; | eipsw            | <- SP+48
 ; +------------------+
 ; | R20              | <- SP+52
 ; +------------------+
 ; | R19              | <- SP+56
 ; +------------------+
 ; | R18              | <- SP+60
 ; +------------------+
 ; | R17              | <- SP+64
 ; +------------------+
 ; | R16              | <- SP+68
 ; +------------------+
 ; | R15              | <- SP+72
 ; +------------------+
 ; | R14              | <- SP+76
 ; +------------------+
 ; | R13              | <- SP+80
 ; +------------------+
 ; | R12              | <- SP+84
 ; +------------------+
 ; | R11              | <- SP+88
 ; +------------------+
 ; | R10              | <- SP+92
 ; +------------------+
 ; | R9               | <- SP+96
 ; +------------------+
 ; | R8               | <- SP+100
 ; +------------------+
 ; | R7               | <- SP+104
 ; +------------------+
 ; | R6               | <- SP+108
 ; +------------------+
 ; | R5               | <- SP+112
 ; +------------------+
 ; | R4               | <- SP+116
 ; +------------------+
 ; | R2               | <- SP+120
 ; +------------------+
 

__tpl_sc_handler:
	; Save working registers on the calling task stack
	pushsp r2, r2
	pushsp r4, r10
	sub 40, sp ; skip caller saved registers: r11-r20

	stsr 1, r20 ; retrieve eipsw: calling status
	pushsp r20, r20
	stsr 0, r20 ; retrieve eipc: calling pc
	pushsp r20, r20
	pushsp r21, r31

	; Check if we already use the kernel stack
	; tpl_reentrancy_counter++
	mov	#_tpl_reentrancy_counter, r10
	ld.w [r10], r11
	add 1, r11
	st.w r11, [r10]

	; tpl_reentrancy_counter == 1 ?
	cmp	1, r11
	bne	tpl_enter_kernel_end
	; yes =>  Switch to the kernel stack and save the current task SP

	mov r3, r20	; save current sp

	movhi HIGHW1(#_tpl_kernel_stack_bottom), r0, r11 ; load kernel sp from structure
	movea LOWW(#_tpl_kernel_stack_bottom), r11, r3 ; update sp

tpl_enter_kernel_end:
	
	; We have now kernel stack

	; Reset the tpl_need_switch variable to NO_NEED_SWITCH before
	; calling the service. This is needed because, beside
	; tpl_schedule, no service modify this variable. So an old value
	; is retained.
	mov NO_NEED_SWITCH_NOR_SCHEDULE, r10
	mov #_tpl_kern, r12
	st.w r10, TPL_KERN_OFFSET_NEED_SWITCH[r12]

	; Call the service
	; => r6-r9 SHOULD NOT HAVE BEEN MODIFIED BEFORE CALLING
	;    THE SERVICE (it contains service arguments)

#if ISR_COUNT != 0
	#pragma "error needs to implement switch to correct context"
#endif //ISR_COUNT

	; Retrieve eiic: sycall number
	stsr 13, r12
	; eiic contains 0x8000 + syscall number, clear bit 15:
	andi 0x7FFF, r12, r10

	; Check syscall count:
	cmp SYSCALL_COUNT, r10
	bge tpl_end_call

	; Ok, syscall is in the correct range.
	; Now find the function in the dispatch table.

	shl 2, r10 ; multiply by 4 for offset computation

	movhi HIGHW1(#_tpl_dispatch_table), r10, r11
	ld.w LOWW(#_tpl_dispatch_table)[r11], r10

	jarl [r10], r31 ; Call service function

	; Save return argument from service (r10) on user stack
	st.w r10, 56[r20] ; We should use a defined value instead of 56

tpl_end_call:
	; Check the tpl_need_switch variable
	; to see if a switch should occur

	mov #_tpl_kern, r12
	ld.w TPL_KERN_OFFSET_NEED_SWITCH[r12], r10

	andi NEED_SWITCH, r10, r11
	bz no_context_switch

	; There is a context switch :
	; Check if context of the task/isr that just lost the CPU needs
	; to be saved. No save is needed for a TerminateTask or ChainTask
	andi NEED_SAVE, r10, r11
	bz no_save

	; Ok, we have to save the current context.
	mov TPL_KERN_OFFSET_S_RUNNING, r10
	movhi HIGHW1(#_tpl_kern), r10, r11 ; get pointer to the descriptor of the running task
	ld.w LOWW(#_tpl_kern)[r11], r10

	st.w r20, [r10] ; save running task sp

no_save:
	; Call tpl_run_elected() to get the SP of the elected task.
	mov r11, r6 ; call with the SAVE value.
	jarl _tpl_run_elected, r31

	; Update the current context according to SP given by the OS
	mov TPL_KERN_OFFSET_S_RUNNING, r10
	movhi HIGHW1(#_tpl_kern), r10, r11 ; Get pointer to the descriptor of the new running task
	ld.w LOWW(#_tpl_kern)[r11], r10

	ld.w [r10], r11 ; Get SP of elected task
	ld.w [r11], r20

no_context_switch:

	;tpl_reentrancy_counter--
	mov	#_tpl_reentrancy_counter, r10
	ld.w [r10], r11

	mov 1, r12
	sub r12, r11
	st.w r11, [r10]

	; tpl_reentrancy_counter == 0?
	and	r11, r11
	bnz tpl_leave_kernel_end
	; yes => tpl_switch_to_kernel_stack
	mov r20, r3	; restore sp

tpl_leave_kernel_end:
	; epilogue

	popsp r21, r31
	popsp r20, r20
	ldsr r20, 0 ; restore eipc: calling pc
	popsp r20, r20
	ldsr r20, 1 ; restore eipsw: calling status
	popsp r4, r20
	popsp r2, r2

	eiret
