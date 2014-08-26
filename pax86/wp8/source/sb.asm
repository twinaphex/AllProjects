;=============================================================================
; sb.S
;
; This file contains the SoundBlaster emulation routines.
;
;	HandleSBCommand()		This routine handles the SB DSP command sent via
;							SB I/O ports (see ports_SB.S), and prepares the
;							internal sb variables. This routine runs in the
;							cpu_core thread context.
;	SBEmulation()			This routine generates audio samples based on the
;							internal sb variables. This runs in the audio
;							thread context.
;
; This file is part of the x86 emulation core written in ARM Assembly, originally
; from the DSx86 Nintendo DS DOS Emulator. See http://dsx86.patrickaalto.com
;
; Copyright (c) 2009-2013 Patrick "Pate" Aalto
;	
; Redistribution and use in source or binary form, with or without modifications,
; is NOT permitted without specific prior written permission from the author.
;
; THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
; WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
; AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE
; LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
; EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;=============================================================================

	INCLUDE ../include/defines.inc
	INCLUDE ../include/macros.inc

	EXTERN	registers
	
	EXTERN	dsp_cmd
	EXTERN	dsp_in_data
	EXTERN	INTVectors
	EXTERN	DMAAddress
	EXTERN	Port61Data
	EXTERN	SpeakerIncr
	EXTERN	DMALength
	EXTERN	DMACurrent
	EXTERN	DirectDACIncr
	EXTERN	SBIRQ

;========== SoundBlaster DSP handling variables =======================

SB_IDLE				EQU		0
SB_NEED_PLAY		EQU		1
SB_PLAYING			EQU		2
SB_BUFFER_END		EQU		3
SB_NEED_ADPCM4		EQU		4
SB_NEED_ADPCM2		EQU		5
SB_NEED_ADPCM26		EQU		6
SB_PLAY_ADPCM4		EQU		7
SB_PLAY_ADPCM2		EQU		8
SB_PLAY_ADPCM26		EQU		9
SB_NEED_SILENCE		EQU		10
SB_PLAY_SILENCE		EQU		11
SB_NEED_AUTODMA		EQU		12
SB_PLAY_AUTODMA		EQU		13
SB_PLAY_DIRECT		EQU		14
SB_PLAY_MASKED		EQU		15

DMALengthOffs		EQU		4
DMACurrentOffs		EQU		8

DAC_BUF_SIZE		EQU		(8*1024)
ADPCM_BUF_SIZE		EQU		1024

	AREA sb_bss, NOINIT, READWRITE
	ALIGN	4

	GLOBAL	sb_play_serialize_start			; For serialization!
sb_play_serialize_start

dac_buf							; Buffer for Direct DAC samples
	SPACE	DAC_BUF_SIZE
	
adpcm_buf							; Buffer for decoded ADPCM samples
	SPACE	ADPCM_BUF_SIZE
	
	GLOBAL	sb_mode
sb_mode							; +0 One of the defines above
	SPACE	4
	GLOBAL	sb_request_pointer
sb_request_pointer					; +20
	SPACE	4
sb_request_length					; +16
	SPACE	4
sb_request_increment
	SPACE	4
sb_dma_total
	SPACE	4
	;------
	; PC Speaker emulation
	;------
sb_speaker_counter
	SPACE	4
	;------
	; Direct DAC variables
	;------
sb_dac_write						; Write position
	SPACE	4
sb_dac_read						; 16.16 read position
	SPACE	4
	;------
	; Playing variables used in SBEmulation
	;------
	GLOBAL	sb_buffer_start			; For serialization
sb_buffer_start
	SPACE	4
	GLOBAL	sb_buffer_end			; For serialization
sb_buffer_end
	SPACE	4
	GLOBAL	sb_buffer_position
sb_buffer_position
	SPACE	4
sb_buffer_increment
	SPACE	4
	
sb_adpcm_haveref					; Do we have a reference byte at the start of the ADPCM buffer to play?
	SPACE	1
sb_adpcm_reference					; ADPCM Reference byte storage
	SPACE	1
sb_adpcm_stepsize					; ADPCM Stepsize
	SPACE	1
sb_adpcm26_counter					; Counter for 2.6-bit ADPCM buffer filling
	SPACE	1
sb_dma_autoinit
	SPACE	1
sb_speaker							; Speaker status
	SPACE	1
	
	GLOBAL	sb_play_serialize_end			; For serialization!
sb_play_serialize_end

	AREA sb_code, CODE, READONLY
	ALIGN	4

	MACRO
	SET_START_ADDR_r0r1r3
		ldr		r0, =INTVectors
		ldr		r3, =DMAAddress
		ldr		r0, [r0]
		ldr		r1, [r3]
		add		r0, r1									;		r0 = INTVectors + DMAAddress
		str		r0, [r3, #DMACurrentOffs]
		str		r0, [r2, #(sb_request_pointer-sb_mode)]	;		sb_request_pointer = (int *)((DOSRAMAddress+SBAddress));
	MEND

	;------
	; Handle a DSP command. The command is in dsp_cmd, dsp_cmd_len gives
	; the length of the command, and possible parameters are in dsp_in_data.
	; We can use r0..r3, must save all other registers.
	; Return address is in lr register.
	;------
	GLOBAL	HandleSBCommand
HandleSBCommand
	ldr		r2, =dsp_cmd
	ldrb	r0, [r2]						; r0 = command byte
	ldr		r2, =sb_mode
	cmp		r0, #0x10						; case 0x10:				; Output direct DAC sample byte
	beq		send_direct_dac
	cmp		r0, #0x14						; case 0x14:				; Start 8-bit sound playing
	beq		start_8bit_pcm
	cmp		r0, #0x40						; case 0x40:				; Set TIME_CONSTANT
	beq		set_time_constant
	cmp		r0, #0x48						; case 0x48:				; Set DMA_LENGTH
	beq		set_DMA_length
	cmp		r0, #0x91						; case 0x91:				; Start 8-bit high-speed sound playing
	beq		start_highspeed_8bit_pcm
	cmp		r0, #0x1C						; case 0x1C:				; Start autoinit 8-bit sound playing
	beq		start_8bit_autoinit_pcm
	cmp		r0, #0x75						; case 0x75:				; Start 4-bit ADPCM sound playing, with reference byte
	beq		start_ADPCM4_ref_byte
	cmp		r0, #0x74						; case 0x74:				; Start 4-bit ADPCM sound playing
	beq		start_ADPCM4
	cmp		r0, #0x17						; case 0x17:				; Start 2-bit ADPCM sound playing, with reference byte
	beq		start_ADPCM2_ref_byte
	cmp		r0, #0x16						; case 0x16:				; Start 2-bit ADPCM sound playing
	beq		start_ADPCM2
	cmp		r0, #0x77						; case 0x77:				; Start 2.6-bit ADPCM sound playing, with reference byte
	beq		start_ADPCM26_ref_byte
	cmp		r0, #0x76						; case 0x76:				; Start 2.6-bit ADPCM sound playing
	beq		start_ADPCM26
	cmp		r0, #0x80						; case 0x80:				; Silence DAC = output silent samples of length bytes
	beq		start_silence
	cmp		r0, #0xD0						; case 0xD0:				; Halt DMA operation
	beq		halt_dma
	cmp		r0, #0xD1						; case 0xD1:				; Enable speaker
	beq		enable_speaker
	cmp		r0, #0xD3						; case 0xD3:				; Disable speaker
	beq		disable_speaker
	cmp		r0, #0xD4						; case 0xD4:				; Continue DMA operation
	beq		continue_auto_dma
	cmp		r0, #0xDA						; case 0xDA:				; Exit Auto-Initialize DMA Operation, 8-bit
	beq		stop_auto_dma
	bx		lr

	;------
	; 010h       Direct DAC, 8-bit                                       SB
    ;	COMMAND->SAMPLEBYTE
	;
    ;	DESCRIPTION
    ;	 Outputs single sample.
	;
    ;	PROCEDURE
    ;	  a) Send Direct DAC, 8-bit command (010h) and sample
    ;	  b) Wait for correct timing
	;
    ;	NOTES
    ;	 * Direct mode maximum sample rate is 23KHz.
	;------
send_direct_dac
	ldr		r3, =dsp_in_data
	sub		r0, r2, #(ADPCM_BUF_SIZE+DAC_BUF_SIZE)		; Point r0 to DAC buffer start
	ldr		r1, [r2, #(sb_dac_write - sb_mode)]
	ldrb	r3, [r3]									; r3 = 8-bit sample byte
	strb	r3, [r0, r1]								; Save it to DAC ring buffer
	mov		r0, #SB_PLAY_DIRECT
	add		r1, #1
	bic		r1, #DAC_BUF_SIZE
	strb	r0, [r2]									; Save sb_mode = SB_PLAY_DIRECT
	str		r1, [r2, #(sb_dac_write - sb_mode)]			; Save new DAC write position
	bx		lr

	;------
	;	014h       DMA DAC, 8-bit                                          SB
	;		COMMAND->LENGTHLOBYTE->LENGTHHIBYTE
	;
	;		DESCRIPTION
	;		 Initiates 8-bit DMA transfer.
	;
	;		PROCEDURE
	;		  a) Install IRQ handler (hook vector, update PIC mask)
	;		  b) Perform Set Time Constant command (040h), or otherwise set sample rate
	;		  c) Perform Enable Speaker command (0D1h)
	;		  d) Setup DMA controller (mode = 048h + channel)
	;		  e) Perform DMA DAC, 8-bit command (014h)
	;		  f) IRQ: Acknowledge IRQ (input from IRQ Acknowledge, 8-bit port - 02x0Eh;
	;								   perform Generic EOI (020h) to appropriate PICs)
	;		  g) Perform Disable Speaker command (0D3h)
	;
	;		LENGTH = SAMPLES - 1
	;------
start_8bit_pcm
	mov		r1, #SB_NEED_PLAY
	;------
	; Play silence if the speaker is not enabled. Fixes screching sound in Ishar
	;------
	ldrb	r0, [r2, #(sb_speaker-sb_mode)]
	cmp		r0, #0
	moveq	r1, #SB_NEED_SILENCE
start_with_length	
	ldr		r3, =dsp_in_data
	push	{r1}
	mov		r0, #0
	strb	r0, [r2, #(sb_dma_autoinit-sb_mode)]	;		sb_dma_autoinit = 0;
	ldrh	r0, [r3]
	add		r0, #1
	str		r0, [r2, #(sb_dma_total-sb_mode)]		;		sb_dma_total = (SBCommand & 0xFFFF) + 1;
	SET_START_ADDR_r0r1r3							;		Setup DMACurrent and sb_request_pointer
	pop		{r1}
	strb	r1, [r2]								;		sb_mode = SB_NEED_PLAY or SB_PARTIAL_PLAY
	bx		lr

start_ADPCM2_ref_byte								; Start 2-bit ADPCM sound playing, with reference byte
	mov		r0, #1
	strb	r0, [r2, #(sb_adpcm_haveref-sb_mode)]
start_ADPCM2										; Start 2-bit ADPCM sound playing
	mov		r1, #SB_NEED_ADPCM2
	b		start_with_length

	;------
	;	 01Ch       Auto-Initialize DMA DAC, 8-bit                          SB2.0
	;		COMMAND
	;
	;		DESCRIPTION
	;		 Initiates auto-initialize 8-bit DMA transfer.
	;
	;		PROCEDURE
	;		  a) Install IRQ handler (hook vector, update PIC mask)
	;		  b) Perform Set Time Constant command (040h), or otherwise set sample rate
	;		  c) Perform Set DMA Block Size command (048h)
	;		  d) Perform Enable Speaker command (0D1h)
	;		  e) Setup DMA controller (mode = 058h + channel)
	;		  f) Perform Auto-Initialize DMA DAC, 8-bit command (01Ch)
	;		  g) IRQ: Prepare next half of buffer (not always in handler)
	;		  h) IRQ: Acknowledge IRQ (input from IRQ Acknowledge, 8-bit port - 0x0Eh;
	;								   perform Generic EOI (020h) to appropriate PICs)
	;		  i) Loop to G until complete
	;		  j) Perform Disable Speaker command (0D3h)
	;		  k) Perform Halt DMA Operation, 8-bit command (0D0h - for virtual speaker)
	;		  l) Perform Exit Auto-Initialize DMA Operation, 8-bit command (0DAh)
	;		  m) Perform Halt DMA Operation, 8-bit command (0D0h - for virtual speaker)
	;
	;		NOTES
	;		 * Supports up to 23KHz (11.5KHz stereo???)
	;		 * Exit auto-initialized mode by programming single-cycle DMA output or
	;			with Exit Auto-Initialize DMA Operation, 8-bit (0DAh).
	;		 * Use command 0Cxh to avoid SoundBlaster 16 quantization errors.     
	;
	;		LENGTH = (SAMPLES + 1)/2 - 1
	;------
start_8bit_autoinit_pcm
	mov		r0, #1
	strb	r0, [r2, #(sb_dma_autoinit-sb_mode)]	;		sb_dma_autoinit = 1;
	SET_START_ADDR_r0r1r3							;		Setup DMACurrent and sb_request_pointer
	mov		r0, #SB_NEED_AUTODMA
	strb	r0, [r2]								;		sb_mode = SB_NEED_AUTODMA; (ignore existing partial buffer)
	bx		lr

continue_auto_dma
	;------
	; Make sure we actually can continue!
	;------
	ldr		r0, [r2, #(sb_buffer_start-sb_mode)]
	ldr		r1, [r2, #(sb_buffer_increment-sb_mode)]	; t4 = input buffer incrementer (16.16 fixed point)
	cmp		r0, #0
	bxeq	lr
	cmp		r1, #0
	bxeq	lr
	ldr		r0, [r2, #(sb_dma_total-sb_mode)]			; t8 = sb_dma_total (IRQ block size)
	ldr		r1, [r2, #(sb_buffer_end-sb_mode)]			; t9 = sb_buffer_end (for total buffer size)
	cmp		r0, #0
	bxeq	lr
	cmp		r1, #0
	bxeq	lr
	;------
	; OK, possible to continue, so do it!
	;------
	mov		r0, #SB_PLAY_AUTODMA
	strb	r0, [r2]								;		sb_mode = SB_PLAY_AUTODMA
	bx		lr
	
stop_auto_dma
	mov		r0, #0
	strb	r0, [r2, #(sb_dma_autoinit-sb_mode)]	;		sb_dma_autoinit = 0;
halt_dma
	mov		r0, #SB_IDLE
	strb	r0, [r2]								;		sb_mode = SB_NONE
	bx		lr

	;------
	;	The DSP_TIME_CONSTANT sets the frequency of reproduction, where 
	;		(BYTE)TIME_CONSTANT = 256 - 1000000 / frequency
	; This method allow a sampling rate of max 22222 Hz (Normal Mode).
	; With SB 2.0 or above, we can have a higher frequency, using High Speed mode.
	; The TIME_COSTANT will be computed in this way: 
	;		(WORD)TIME_CONSTANT = 65535 - 256000000 / frequency
	; The result is a WORD, but we'll send only the MSB to the DSP.
	;
	; => freq * TIME_CONSTANT = freq * 256 - 1000000
	; => freq * TIME_CONSTANT - freq * 256 = - 1000000
	; => freq * (256 - TIME_CONSTANT) = 1000000
	; => freq = 1000000 / (256 - TIME_CONSTANT)
	; => incrementer = 65536 * ((1000000 / (256 - TIME_CONSTANT)) / 32000)
	;				  = (65536 * 1000000 / 32000) / (256 - TIME_CONSTANT)
	;				  = 2048000 / (256 - TIME_CONSTANT)
	;
	; Example: TIME_CONSTANT = 163 => freq = 10752 => incrementer = 22021 (= 0.336)
	;
	;------
set_time_constant
	ldr		r1, =dsp_in_data
	ldr		r3, =sb_incr_table
	ldrb	r0, [r1]						; t0 = TIME_CONSTANT byte
	ldr		r0, [r3, r0, lsl #2]			; r0 = incrementer value from LUT
	str		r0, [r2, #(sb_request_increment-sb_mode)]	; Save the incrementer value.
	bx		lr

	;------
	;	 048h       Set DMA Block Size                                      SB2.0
	;		COMMAND->LENGTHLOBYTE->LENGTHHIBYTE
	;
	;		DESCRIPTION
	;		 Set DMA transfer size for auto-initialize and high speed modes.
	;
	;		SAMPLEBYTES =  SAMPLES                    8-bit
	;					  (SAMPLES-1   + 1)/2 + 1     4-bit ADPCM + Reference
	;					  (SAMPLES-1   + 2)/3 + 1   2.6-bit ADPCM + Reference
	;					  (SAMPLES-1   + 3)/4 + 1     2-bit ADPCM + Reference
	;
	;		LENGTH      =  SAMPLEBYTES        - 1  (Single Cycle)
	;					  (SAMPLEBYTES + 1)/2 - 1  (Auto-Init   )
	;
	;		NOTES
	;		 * Length is always equal to the number of bytes to transfer minus one.
	;------
set_DMA_length
	ldr		r3, =dsp_in_data
	ldrh	r0, [r3]
	add		r0, #1
	str		r0, [r2, #(sb_dma_total-sb_mode)]	;		sb_dma_total = (SBCommand & 0xFFFF) + 1;
	bx		lr
	
start_highspeed_8bit_pcm
	mov		r0, #0
	strb	r0, [r2, #(sb_dma_autoinit-sb_mode)]	;		sb_dma_autoinit = 0;
	SET_START_ADDR_r0r1r3							;		Setup DMACurrent and sb_request_pointer
	mov		r0, #SB_NEED_PLAY
	strb	r0, [r2]								;		sb_mode = SB_NEED_PLAY or SB_PARTIAL_PLAY
	bx		lr

	;------
	; 075h       DMA DAC, 4-bit ADPCM Reference                          SB
	;    COMMAND->LENGTHLOBYTE->LENGTHHIBYTE
	;
	;    DESCRIPTION
	;     Initiates 4-bit ADPCM DMA transfer with new reference byte.  This
	;    operation uses 8-bit DMA mode.
	;
	;    PROCEDURE
	;      a) Install IRQ handler (hook vector, update PIC mask)
	;      b) Perform Set Time Constant command (040h), or otherwise set sample rate
	;      c) Perform Enable Speaker command (0D1h)
	;      d) Setup DMA controller (mode = 048h + channel)
	;      e) Perform DMA DAC, 4-bit ADPCM Reference command (075h)
	;      f) IRQ: Acknowledge IRQ (input from IRQ Acknowledge, 8-bit port - 02x0Eh;
	;                               perform Generic EOI (020h) to appropriate PICs)
	;      g) Perform Disable Speaker command (0D3h)
	;
	;    LENGTH      = (SAMPLES-1   + 1)/2 + 1
	;
	;    NOTES
	;     * Supports up to 12KHz on SoundBlaster 1.x  
	;     * Ensoniq Soundscape does not support ADPCM.
	;
	;    SEE ALSO
	;     0D0h   Halt DMA Operation, 8-bit
	;     0D4h   Continue DMA Operation, 8-bit
	;     -----------------------------------------------------
	;     075h   DMA DAC, 4-bit ADPCM
	;     -----------------------------------------------------
	;     017h   DMA DAC, 2-bit ADPCM Reference
	;     077h   DMA DAC, 2.6-bit ADPCM Reference
	;------
start_ADPCM4_ref_byte								; Start 4-bit ADPCM sound playing, with reference byte
	mov		r0, #1
	strb	r0, [r2, #(sb_adpcm_haveref-sb_mode)]
start_ADPCM4										; Start 4-bit ADPCM sound playing
	mov		r1, #SB_NEED_ADPCM4
	b		start_with_length

start_ADPCM26_ref_byte							; Start 2.6-bit ADPCM sound playing, with reference byte
	mov		r0, #1
	strb	r0, [r2, #(sb_adpcm_haveref-sb_mode)]
start_ADPCM26										; Start 2.6-bit ADPCM sound playing
	mov		r1, #SB_NEED_ADPCM26
	b		start_with_length

start_silence										; Silence DAC = output silent samples of length bytes, then IRQ
	mov		r1, #SB_NEED_SILENCE
	b		start_with_length

enable_speaker
	mov		r0, #1
	strb	r0, [r2, #(sb_speaker-sb_mode)]
	bx		lr

disable_speaker
	mov		r0, #0
	strb	r0, [r2, #(sb_speaker-sb_mode)]
	bx		lr

	MACRO
	COPY_SAMPLES $mask
	;-------
	; Input:
	;	r0 = output buffer address
	;	r1 = input buffer start address
	;	r2 = sb_buffer_end value
	;	r3 = current 16.16 buffer pointer
	;	r4 = current buffer incrementer value
	;	r5 = output buffer remaining length
	; Output:
	;	r2 = sb_buffer_end value
	;	r3 = new 16.16 buffer pointer
	;	r5 = output buffer remaining length
	; Destroyed:
	;	r6 = temp sample value
	;	r7 = temp sample value
	;-------
	IF "$mask" = ""
1	lsr		r6, r3, #16								; Get the sample position
	ELSE
1	and		r6, $mask, r3, lsr #16					; Mask the sample position
	ENDIF
	ldrb	r6, [r1, r6]							; Get one sample byte
	add		r3, r4									; Increment the 16.16 sample pointer	
	ldrh	r7, [r0]								; Get current sample from output buffer (AdLib sample)
	sub		r6, #0x80
	lsl		r6, #7									; r6 = 16-bit signed sample from the 8-bit SB sample buffer
	;-------
	; Check the output buffer remaining length
	;-------
	subs	r5, #1
	blt		%f1
	;-------
	; Mix the sample to the output buffer
	;-------
	qadd16	r7, r7, r6								; Mix the SB sample to the AdLib buffer
	strh	r7, [r0], #2							; Write the mixed output sample
	;-------
	; Check the input buffer remaining length
	;-------
	add		r7, r1, r3, lsr #16
	cmp		r7, r2
	blt		%b1
	;-------
	; Done, we ran out of either input or output buffer.
	;-------
1	addlt	r5, #1									; If we stopped because of output buffer end, restore r5
	MEND

	;-------
	; Input:
	;	r0 = output buffer pointer
	;	r1 = output buffer length
	; Output:
	;	r0 = remaining output buffer length
	;-------
	GLOBAL	SBEmulation
SBEmulation
	push	{r4-r11, lr}
	mov		r5, r1						; r5 = output buffer length
	;-------
	; Get pointer to SB buffer (all other SB variables are accessed relative to this)
	;-------
	ldr		r12,=sb_mode
	;-------
	; Check the current SoundBlaster playing mode
	;-------
	ldr		r1, [r12]					; Get sb_mode
	adr		r2, %f1
	ldr		pc, [r2, r1, lsl #2]		; Jump to the handler
	ALIGN	4
1	DCD	sb_pc_speaker				; SB_IDLE			0
	DCD	sb_1_start_pcm				; SB_NEED_PLAY		1
	DCD	sb_2_play_pcm				; SB_PLAYING		2
	DCD	sb_3_buf_end				; SB_BUFFER_END		3
	DCD	sb_4_start_adpcm4			; SB_NEED_ADPCM4	4
	DCD	sb_5_start_adpcm2			; SB_NEED_ADPCM2	5
	DCD	sb_6_start_adpcm26			; SB_NEED_ADPCM26	6
	DCD	sb_7_play_adpcm4			; SB_PLAY_ADPCM4	7
	DCD	sb_8_play_adpcm2			; SB_PLAY_ADPCM2	8
	DCD	sb_9_play_adpcm26			; SB_PLAY_ADPCM26	9
	DCD	sb_10_start_silence			; SB_NEED_SILENCE	10
	DCD	sb_11_play_silence			; SB_PLAY_SILENCE	11
	DCD	sb_12_start_auto_pcm		; SB_NEED_AUTODMA	12
	DCD	sb_13_play_auto_pcm			; SB_PLAY_AUTODMA	13
	DCD	sb_14_play_direct			; SB_PLAY_DIRECT	14
	DCD	sb_15_play_pcm_masked		; SB_PLAY_MASKED	15

	;=======
	; SoundBlaster is idle, so play PC speaker sounds if needed.
	;=======
sb_pc_speaker
	ldr		r2, =Port61Data
	ldr		r4, =SpeakerIncr
	ldrb	r2, [r2]
	ldr		r4, [r4]
	and		r2, #3										; Check the speaker bits
	cmp		r2, #3
	bne		sb_done										; Speaker not on, so all done here.
	ldr		r3, [r12, #(sb_speaker_counter-sb_mode)]	; Get current speaker counter value
	;-------
	; Loop here generating square wave samples
	;-------
1	ldrh	r7, [r0]									; Get current sample from output buffer (AdLib sample)
	add		r3, r4										; Increment the 16.16 sample pointer	
	tst		r3, #0x10000
	mov		r6, #0x4000
	subne	r6, #0x8000
	;-------
	; Check the output buffer remaining length
	;-------
	subs	r5, #1
	blt		%f1
	;-------
	; Mix the sample to the output buffer
	;-------
	qadd16	r7, r7, r6									; Mix the SB sample to the AdLib buffer
	strh	r7, [r0], #2								; Write the mixed output sample
	b		%b1
1	addlt	r5, #1										; If we stopped because of output buffer end, restore r5
	str		r3, [r12, #(sb_speaker_counter-sb_mode)]	; Save new speaker counter value
	b		sb_done
	
	;=======
	; We need to start playing a digital sample
	; First copy the HandleSBCommand variables to the current playing variables.
	; On input, r12 = pointer to sb_mode
	;=======
sb_1_start_pcm
	ldr		r1, [r12, #(sb_request_pointer-sb_mode)]	; t1 = sb_request_pointer
	ldr		r2, [r12, #(sb_dma_total-sb_mode)]			; t2 = sb_dma_total
	ldr		r4, [r12, #(sb_request_increment-sb_mode)]	; t4 = sb_request_increment (16.16 fixed point)
	movs	r3, r2, lsl #16								; r3 = end 16.16 position (for short buffer)
	subeq	r2, #1										; If we are to play 65536 samples, play only 65535 (NHL '94)!
	cmp		r2, #4										; Are we to play < 4 samples (Alone in the Dark)?
	add		r2, r1										; t2 = end address of the input buffer
	str		r1, [r12, #(sb_buffer_start-sb_mode)]		; Remember the start address of this DMA transfer
	str		r2, [r12, #(sb_buffer_end-sb_mode)]
	mov		r6, #0
	str		r6, [r12, #(sb_buffer_position-sb_mode)]	; Clear the 16.16 fixed point position
	str		r4, [r12, #(sb_buffer_increment-sb_mode)]
	blt		samples_copied								; If buffer < 4, jump directly to end.
	;------
	; Determine if we need to mask the playing position.
	; (DMALength < sb_dma_total/2, and DMALength+1 is a power-of-two)
	; See http://graphics.stanford.edu/~seander/bithacks.html
	; NHL '94: DMALength = 0xFF, sb_dma_length = r2 = 0xFFFF (originally 0x10000)
	;------
	ldr		r8, =DMALength								; Get DMA length address (NHL '94)
	sub		r6, r2, r1									; r6 = sb_dma_total
	ldr		r8, [r8]									; Get DMA length mask (NHL '94)
	cmp		r8, r6, lsr #1								; DMALength < sb_dma_total / 2?
	add		r1, r8, #1
	andslt	r1, r8										; Is r8 a power-of-two - 1?
	mov		r1, #SB_PLAYING
	moveq	r1, #SB_PLAY_MASKED
	;------
	; Mark that we are currently playing
	;------
	strb	r1, [r12]
	beq		sb_15_play_pcm_masked						; Play a masked buffer (NHL '94)
	;------
	; Flow-thru to fill the output buffer!
	;------
	;=======
	; We are currently playing, so fill buffer and continue playing.
	;=======
sb_2_play_pcm
	ldr		r1, [r12, #(sb_buffer_start-sb_mode)]
	ldr		r2, [r12, #(sb_buffer_end-sb_mode)]
	ldr		r3, [r12, #(sb_buffer_position-sb_mode)]	; t3 = input buffer position (16.16 fixed point)
	ldr		r4, [r12, #(sb_buffer_increment-sb_mode)]	; t4 = input buffer incrementer (16.16 fixed point)
	;------
	; Copy audio_samples_per_trans worth of samples.
	;------
	COPY_SAMPLES										; Updates t3, destroys t0, t5, t6, t7
	;------
	; Save the new buffer position
	;------
samples_copied
	ldr		r4, =DMACurrent
	str		r3, [r12, #(sb_buffer_position-sb_mode)]	; Store the 16.16 fixed point position
	add		r3, r1, r3, lsr #16							; r3 = physical current buffer position
	str		r3, [r4]									; Store the DMACurrent position
sb_check_done
	;------
	; Check if all done (if (t1 + (t3>>16)) >= t2, all done)
	;------
	cmp		r3, r2
	blt		sb_done										; Did not run out of input buffer, so just continue.
	;------
	; Input done, so send an SB IRQ.
	;------
	bl		SBIRQ										; SBIRQ only changes r0..r3 (and lr)
	;------
	; Go to idle mode
	;------
	mov		r3, #SB_IDLE
	strb	r3, [r12]									; Go to SB_NONE mode
sb_done	
	mov		r0, r5										; r0 = remaining output buffer length
sb_3_buf_end
	pop		{r4-r11, pc}

	;=======
	; We are currently playing, so fill buffer and continue playing.
	; This is used when the DMALength is a subrange of sb_dma_total.
	; Used in NHL '94, for example.
	;=======
sb_15_play_pcm_masked
	ldr		r8, =DMALength								; Get DMA length address (NHL '94)
	ldr		r1, [r12, #(sb_buffer_start-sb_mode)]
	ldr		r2, [r12, #(sb_buffer_end-sb_mode)]
	ldr		r8, [r8]									; Get DMA length mask (NHL '94)
	ldr		r3, [r12, #(sb_buffer_position-sb_mode)]	; t3 = input buffer position (16.16 fixed point)
	ldr		r4, [r12, #(sb_buffer_increment-sb_mode)]	; t4 = input buffer incrementer (16.16 fixed point)
	;------
	; Copy audio_samples_per_trans worth of samples.
	;------
	COPY_SAMPLES r8										; Updates t3, destroys t0, t5, t6, t7
	;------
	; Save the new buffer position
	;------
	ldr		r4, =DMACurrent
	str		r3, [r12, #(sb_buffer_position-sb_mode)]	; Store the 16.16 fixed point position
	and		r6, r8, r3, lsr #16							; r6 = masked current position
	add		r3, r1, r3, lsr #16							; r3 = physical current buffer position
	add		r6, r1										; r6 = DMA masked physical current position
	str		r6, [r4]									; Store the DMACurrent position
	b		sb_check_done

	;=======
	; We need to start playing a auto-init digital sample buffer.
	; First copy the HandleSBCommand variables to the current playing variables.
	; On input, r12 = pointer to sb_mode
	;=======
sb_12_start_auto_pcm
	ldr		r11, =DMALength
	ldr		r1, [r12, #(sb_request_pointer-sb_mode)]	; t1 = sb_request_pointer
	ldr		r2, [r11]									; t2 = length-1 of the DMA buffer
	ldr		r4, [r12, #(sb_request_increment-sb_mode)]	; t4 = sb_request_increment (16.16 fixed point)
	add		r2, #1
	add		r2, r1										; t2 = end address of the input buffer
	str		r1, [r12, #(sb_buffer_start-sb_mode)]		; Remember the start address of this DMA transfer
	str		r2, [r12, #(sb_buffer_end-sb_mode)]
	mov		r1, #0
	str		r1, [r12, #(sb_buffer_position-sb_mode)]	; Clear the 16.16 fixed point position
	str		r4, [r12, #(sb_buffer_increment-sb_mode)]
	mov		r1, #SB_PLAY_AUTODMA
	strb	r1, [r12]									; Tell we are playing
	;=======
	; We are currently playing, so fill buffer and continue playing.
	;=======
sb_13_play_auto_pcm
	ldr		r1, [r12, #(sb_buffer_start-sb_mode)]
	ldr		r3, [r12, #(sb_buffer_position-sb_mode)]	; t3 = input buffer position (16.16 fixed point)
	ldr		r4, [r12, #(sb_buffer_increment-sb_mode)]	; t4 = input buffer incrementer (16.16 fixed point)
	ldr		r8, [r12, #(sb_dma_total-sb_mode)]			; t8 = sb_dma_total (IRQ block size)
	ldr		r9, [r12, #(sb_buffer_end-sb_mode)]			; t9 = sb_buffer_end (for total buffer size)
	;------
	; Make t2 track the next IRQ position (or table end if less than sb_dma_total samples remaining)
	;------
	mov		r6, r3, lsr #16								; t6 = integer part of input buffer position
	add		r6, r1										; t6 = physical current buffer position
	mov		r2, r9										; t2 = physical buffer end position
1	sub		r2, r8										; do { t2 -= sb_dma_total (IRQ block size)
	cmp		r6, r2
	blt		%b1											; } while ( current pos < t2 );
	add		r2, r8										; t2 = next IRQ sending position
	;------
	; Copy samples until ring buffer filled (t5 == 0) or we are at next IRQ position (t1 + (t3>>16)) >= t2)
	;------
	COPY_SAMPLES										; Updates t3, destroys t0, t5, t6, t7
	;------
	; Calculate t6 = new physical buffer position
	;------
	add		r6, r1, r3, lsr #16							; t6 = physical current buffer position
	;------
	; If we ran to the end of the input buffer, wrap back to start.
	;------
	cmp		r6, r9										; Are we at end of the input buffer?
	movge	r3, #0										; Wrap, rewind the buffer pointer to start
	movge	r6, r1										; Wrap, set current DMA position to the start of the buffer
	movge	r2, r1										; Wrap, mark that we need to send an IRQ
	;------
	; Save the new buffer position
	;------
	ldr		r4, =DMACurrent
	str		r3, [r12, #(sb_buffer_position-sb_mode)]	; Store the 16.16 fixed point position
	str		r6, [r4]									; Store the DMACurrent position
	;------
	; If (t1 + (t3>>16)) >= t2, we need to send an SB IRQ.
	;------
	cmp		r6, r2
	;------
	; Input done, so send an SB IRQ.
	;------
	blge	SBIRQ										; SBIRQ only changes r0..r3 (and lr)
	b		sb_done


	MACRO
	calc_adpcm_sample $offs, $shift
		IF "$offs" = ""
			error "calc_adpcm_sample needs an offs parameter!"
		ENDIF
		IF "$shift" = ""
			error "calc_adpcm_sample needs a shift parameter!"
		ENDIF
		;-------
		; Input:
		;  r0  = adpcm_buf address
		;	r8  = sample (4, 3 or 2 bits unsigned value)
		;	r9  = scaleMap address
		;	r10 = ADPCM reference byte value
		;	r11 = ADPCM stepsize (scale) value, signed byte
		;  lr  = adjustMap address
		; Destroyed:
		;	r6  = temp value
		;	r7  = temp value
		; Output:
		;	r10 = ADPCM reference byte value
		;	r11 = ADPCM stepsize (scale) value, signed byte
		;-------
		;-------
		; Bits samp = sample + scale;
		; if ((samp < 0) || (samp > 63)) { 
		;	LOG(LOG_SB,LOG_ERROR)("Bad ADPCM-4 sample");
		;	if(samp < 0 ) samp =  0;
		;	if(samp > 63) samp = 63;
		; }
		;-------
		IF $offs = 64
		add		r6, r11, r8, lsr #$shift				;	Bits samp = sample + scale;
		usat	r6, #6, r6
		ELSE
		adds	r6, r11, r8, lsr #$shift				;	Bits samp = sample + scale;
		movlt	r6, #0									;	if (samp < 0x00) samp = 0x00;
		cmp		r6, #($offs)-1
		movgt	r6, #($offs)-1							;	if (samp > 23) samp = 23;
		ENDIF
		;-------
		; Bits ref = reference + scaleMap[samp];
		; if (ref > 0xff) reference = 0xff;
		; else if (ref < 0x00) reference = 0x00;
		; else reference = ref;
		;-------
		ldrsb	r7, [r9, r6]							; r7 = scaleMap[samp]
		ldrb	r6, [lr, r6]							; r6 = adjustMap[samp]
		add		r10, r7									; Bits ref = reference + scaleMap[samp];
		usat	r10, #8, r10
		;-------
		; scale = (scale + adjustMap[samp]) & 0xff;
		;-------
		strb	r10, [r0], #1								; Write the reference byte to the adpcm_buf buffer
		add		r11, r6
		and		r11, #0xFF
	MEND

MIN_ADAPTIVE_STEP_SIZE	EQU		0

	;=======
	; We need to start playing a 4-bit ADPCM sample.
	;=======
sb_4_start_adpcm4
	ldr		r1, [r12, #(sb_request_pointer-sb_mode)]	; t1 = sb_request_pointer
	ldr		r2, [r12, #(sb_dma_total-sb_mode)]			; t2 = sb_dma_total
	ldr		r4, [r12, #(sb_request_increment-sb_mode)]	; t4 = sb_request_increment (16.16 fixed point)
	add		r2, r1										; t2 = end address of the input buffer
	str		r1, [r12, #(sb_buffer_start-sb_mode)]		; Remember the start address of this DMA transfer
	str		r2, [r12, #(sb_buffer_end-sb_mode)]
	mov		r3, #0
	str		r3, [r12, #(sb_buffer_position-sb_mode)]	; Clear the integral position
	str		r4, [r12, #(sb_buffer_increment-sb_mode)]
	;------
	; Mark that we are currently playing
	; When starting play, check for a reference byte at the start of the buffer
	;------
	ldrb	r3, [r12, #(sb_adpcm_haveref-sb_mode)]		; Do we have a reference byte in the buffer?
	mov		r4, #SB_PLAY_ADPCM4
	strb	r4, [r12]									; Tell we are playing
	cmp		r3, #0
	beq		sb_7_play_adpcm4							; Nope
	;------
	; We have a reference byte at the beginning.
	;------
	ldrb	r10, [r1]									; Get the reference byte from the start of the data
	mov		r11, #MIN_ADAPTIVE_STEP_SIZE				; Yes, so start with minimum stepsize (scale)
	add		r1, #1
	strb	r10, [r12, #(sb_adpcm_reference-sb_mode)]	; Save the reference byte
	str		r1, [r12, #(sb_buffer_start-sb_mode)]		; Save new input sample start address
	mov		r1, #0
	strb	r1, [r12, #(sb_adpcm_haveref-sb_mode)]		; haveref = 0
	strb	r11,[r12, #(sb_adpcm_stepsize-sb_mode)]		; Save the stepsize (scale) value
	;------
	; Flow-thru to fill the buffer!
	;------
	;=======
	; We are currently playing a 4-bit ADPCM buffer, so refill buffer and continue playing.
	;=======
sb_7_play_adpcm4
	ldr		r1, [r12, #(sb_buffer_start-sb_mode)]		; t1 = input sample start address
	ldr		r2, [r12, #(sb_buffer_end-sb_mode)]			; t2 = sb_buffer_end (for total buffer size)
	ldr		r3, [r12, #(sb_buffer_position-sb_mode)]	; t3 = input buffer position (16.16 fixed point)
	ldr		r4, [r12, #(sb_buffer_increment-sb_mode)]	; t4 = input buffer incrementer (16.16 fixed point)
	ldrb	r10, [r12, #(sb_adpcm_reference-sb_mode)]	; Use the current saved reference byte
	ldrsb	r11, [r12, #(sb_adpcm_stepsize-sb_mode)]	; Load current stepsize (scale) value
	ldr		r9, =scaleMap4
	;------
	; First we need to decode a sufficient number of samples
	; into the adpcm_buf buffer. Decode up to ADPCM_BUF_SIZE samples.
	;------
	push	{r0, r5}
	sub		r0, r12, #ADPCM_BUF_SIZE					; Point r0 to the ADPCM buffer
	add		lr, r9, #64									; lr = adjustMap address
2	mov		r7, r3, lsr #16								; r7 = current integral buffer position value
4	add		r6, r1, r3, lsr #16							; r6 = buffer_start + 16.16 fixed point buffer position
	cmp		r6, r2
	bge		sb_adpcm_decode_done						; All done if we run out of input buffer
	sub		r5, #2										; This would generate two more output samples
	add		r3, r4										; Add incrementer to the buffer position
	cmp		r7, r3, lsr #16								; Did the integral input position change?
	beq		%b4											; Skip ADPCM sample decoding if not yet
	;=======
	; MixTemp[done++]=decode_ADPCM_4_sample(sb.dma.buf.b8[i] >> 4,sb.adpcm.reference,sb.adpcm.stepsize);
	;=======
	ldrb	r8, [r6]									; Get the input byte (2xADPCM samples)
	calc_adpcm_sample 64, 4								; Adjusts r10 & r11, destroys r7
	;=======
	; MixTemp[done++]=decode_ADPCM_4_sample(sb.dma.buf.b8[i]& 0xf,sb.adpcm.reference,sb.adpcm.stepsize);
	;=======
	and		r8, #0xF
	calc_adpcm_sample 64, 0								; Adjusts r10 & r11, destroys r7
	;------
	; Back to loop until we run out of output buffer.
	;------
	cmp		r5, #0										; Out of output buffer?
	bge		%b2											; Not yet, back to loop
	;------
	; ADPCM decoding done, so save ADPCM-related values.
	; If cpu flags = GE, we ran out of input buffer, else we ran out of output buffer.
	;------
sb_adpcm_decode_done
	ldr		r7, =DMACurrent
	ldr		r6, [r12, #(sb_buffer_position-sb_mode)]	; r6 = original input buffer position (16.16 fixed point)
	str		r3, [r12, #(sb_buffer_position-sb_mode)]	; Save the new 16.16 fixed point position
	strb	r10, [r12, #(sb_adpcm_reference-sb_mode)]	; Save the reference byte
	strb	r11, [r12, #(sb_adpcm_stepsize-sb_mode)]	; Save the stepsize (scale) value
	add		r3, r1, r3, lsr #16							; r3 = physical current buffer position
	str		r3, [r7]									; Store the DMACurrent position
	;------
	; If we ran out of input buffer, send an SB IRQ and go to IDLE mode.
	;------
	mrs		r7, cpsr									; Save flags
	blge	SBIRQ										; SBIRQ only changes r0..r3 (and lr)
	ldr		r2, [sp, #4]								; r2 = original r5 value
	msr		cpsr_f, r7									; Restore flags
	movge	r3, #SB_IDLE
	strbge	r3, [r12]									; Go to SB_NONE mode
	subge	r2, r5										; Only leave the number of samples we generated
	mov		r3, r6										; r3 = starting input buffer offset
	pop		{r0, r5}
	;------
	; Mix up to r2 or r5 samples from adpcm_buf to SB playing buffer
	; Registers:
	;	r0 = output buffer write position
	;	r1 = adpcm_buf address
	;	r2 = number of output samples we can generate
	;	r3 = input buffer position (16.16 fixed point value)
	;	r4 = input buffer incrementer (16.16 fixed point value)
	;	r5 = number of output samples we hope to generate
	;	r6 = temp value (8-bit adpcm sample from input)
	;	r7 = temp value (16-bit output sample)
	;	r8 = 
	;	r9 = 
	;	r10 =
	;	r11 =
	;	r12 = pointer to data variables (sb_mode)
	;-------
	sub		r1, r12, #ADPCM_BUF_SIZE					; r1 = adpcm_buf start address
	sub		r1, r3, lsr #16								; r1 = adpcm_buf - input buffer offset
	;------
	; Fill up to r2 (max r5) number of samples
	;------	
1	lsr		r6, r3, #16
	ldrb	r6, [r1, r6]							; Get one sample byte
	add		r3, r4									; Increment the 16.16 sample pointer	
	ldrh	r7, [r0]								; Get current sample from output buffer (AdLib sample)
	sub		r6, #0x80
	lsl		r6, #7									; r6 = 16-bit signed sample from the 8-bit SB sample buffer
	subs	r5, #1
	blt		sb_adpcm_done							; Jump if we ran out of output buffer space
	qadd16	r7, r7, r6								; Mix the SB sample to the AdLib buffer
	strh	r7, [r0], #2							; Write the mixed output sample
	subs	r2, #1									; One less output sample to do
	bge		%b1										; Back to loop
	;------
	; Output buffer filling done
	;------
	b		sb_done									; Done, ran out of input buffer
sb_adpcm_done
	mov		r0, #0									; r0 = remaining output buffer length
	pop		{r4-r11, pc}

sb_5_start_adpcm2
	ldr		r1, [r12, #(sb_request_pointer-sb_mode)]	; t1 = sb_request_pointer
	ldr		r2, [r12, #(sb_dma_total-sb_mode)]			; t2 = sb_dma_total
	ldr		r4, [r12, #(sb_request_increment-sb_mode)]	; t4 = sb_request_increment (16.16 fixed point)
	add		r2, r1										; t2 = end address of the input buffer
	str		r1, [r12, #(sb_buffer_start-sb_mode)]		; Remember the start address of this DMA transfer
	str		r2, [r12, #(sb_buffer_end-sb_mode)]
	mov		r3, #0
	str		r3, [r12, #(sb_buffer_position-sb_mode)]	; Clear the integral position
	str		r4, [r12, #(sb_buffer_increment-sb_mode)]
	;------
	; Mark that we are currently playing
	; When starting play, check for a reference byte at the start of the buffer
	;------
	ldrb	r3, [r12, #(sb_adpcm_haveref-sb_mode)]		; Do we have a reference byte in the buffer?
	mov		r4, #SB_PLAY_ADPCM2
	strb	r4, [r12]									; Tell we are playing
	cmp		r3, #0
	beq		sb_8_play_adpcm2							; Nope
	;------
	; We have a reference byte at the beginning.
	;------
	ldrb	r10, [r1]									; Get the reference byte from the start of the data
	mov		r11, #MIN_ADAPTIVE_STEP_SIZE				; Yes, so start with minimum stepsize (scale)
	add		r1, #1
	strb	r10, [r12, #(sb_adpcm_reference-sb_mode)]	; Save the reference byte
	str		r1, [r12, #(sb_buffer_start-sb_mode)]		; Save new input sample start address
	mov		r1, #0
	strb	r1, [r12, #(sb_adpcm_haveref-sb_mode)]		; haveref = 0
	strb	r11,[r12, #(sb_adpcm_stepsize-sb_mode)]		; Save the stepsize (scale) value
	;------
	; Flow-thru to fill the buffer!
	;------
	;=======
	; We are currently playing a 2-bit ADPCM buffer, so refill buffer and continue playing.
	;=======
sb_8_play_adpcm2
	ldr		r1, [r12, #(sb_buffer_start-sb_mode)]		; t1 = input sample start address
	ldr		r2, [r12, #(sb_buffer_end-sb_mode)]			; t2 = sb_buffer_end (for total buffer size)
	ldr		r3, [r12, #(sb_buffer_position-sb_mode)]	; t3 = input buffer position (16.16 fixed point)
	ldr		r4, [r12, #(sb_buffer_increment-sb_mode)]	; t4 = input buffer incrementer (16.16 fixed point)
	ldrb	r10, [r12, #(sb_adpcm_reference-sb_mode)]	; Use the current saved reference byte
	ldrsb	r11, [r12, #(sb_adpcm_stepsize-sb_mode)]	; Load current stepsize (scale) value
	ldr		r9, =scaleMap2
	;------
	; First we need to decode a sufficient number of samples
	; into the adpcm_buf buffer. Decode up to ADPCM_BUF_SIZE samples.
	;------
	push	{r0, r5}
	sub		r0, r12, #ADPCM_BUF_SIZE					; Point r0 to the ADPCM buffer
	add		lr, r9, #24									; lr = adjustMap address
2	mov		r7, r3, lsr #16								; r7 = current integral buffer position value
4	add		r6, r1, r3, lsr #16							; r6 = buffer_start + 16.16 fixed point buffer position
	cmp		r6, r2
	bge		sb_adpcm_decode_done						; All done if we run out of input buffer
	sub		r5, #4										; This would generate 4 more output samples
	add		r3, r4										; Add incrementer to the buffer position
	cmp		r7, r3, lsr #16								; Did the integral input position change?
	beq		%b4											; Skip ADPCM sample decoding if not yet
	;=======
	; MixTemp[done++]=decode_ADPCM_2_sample((sb.dma.buf.b8[i] >> 6) & 0x3,sb.adpcm.reference,sb.adpcm.stepsize);
	;=======
	ldrb	r8, [r6]									; Get the input byte (2xADPCM samples)
	calc_adpcm_sample 24, 6								; Adjusts r10 & r11, destroys r7
	;=======
	; MixTemp[done++]=decode_ADPCM_2_sample((sb.dma.buf.b8[i] >> 4) & 0x3,sb.adpcm.reference,sb.adpcm.stepsize);
	;=======
	and		r8, #0x3F
	calc_adpcm_sample 24, 4								; Adjusts r10 & r11, destroys r7
	;=======
	; MixTemp[done++]=decode_ADPCM_2_sample((sb.dma.buf.b8[i] >> 2) & 0x3,sb.adpcm.reference,sb.adpcm.stepsize);
	;=======
	and		r8, #0xF
	calc_adpcm_sample 24, 2								; Adjusts r10 & r11, destroys r7
	;=======
	; MixTemp[done++]=decode_ADPCM_2_sample((sb.dma.buf.b8[i] >> 0) & 0x3,sb.adpcm.reference,sb.adpcm.stepsize);
	;=======
	and		r8, #0x3
	calc_adpcm_sample 24, 0								; Adjusts r10 & r11, destroys r7
	;------
	; Back to loop until we run out of output buffer.
	;------
	cmp		r5, #0										; Out of output buffer?
	bge		%b2											; Not yet, back to loop
	b		sb_adpcm_decode_done

sb_6_start_adpcm26
	ldr		r1, [r12, #(sb_request_pointer-sb_mode)]	; t1 = sb_request_pointer
	ldr		r2, [r12, #(sb_dma_total-sb_mode)]			; t2 = sb_dma_total
	ldr		r4, [r12, #(sb_request_increment-sb_mode)]	; t4 = sb_request_increment (16.16 fixed point)
	add		r2, r1										; t2 = end address of the input buffer
	str		r1, [r12, #(sb_buffer_start-sb_mode)]		; Remember the start address of this DMA transfer
	str		r2, [r12, #(sb_buffer_end-sb_mode)]
	mov		r3, #0
	str		r3, [r12, #(sb_buffer_position-sb_mode)]	; Clear the integral position
	str		r4, [r12, #(sb_buffer_increment-sb_mode)]
	;------
	; Mark that we are currently playing
	; When starting play, check for a reference byte at the start of the buffer
	;------
	ldrb	r3, [r12, #(sb_adpcm_haveref-sb_mode)]		; Do we have a reference byte in the buffer?
	mov		r4, #SB_PLAY_ADPCM26
	strb	r4, [r12]									; Tell we are playing
	cmp		r3, #0
	beq		sb_9_play_adpcm26							; Nope
	;------
	; We have a reference byte at the beginning.
	;------
	ldrb	r10, [r1]									; Get the reference byte from the start of the data
	mov		r11, #MIN_ADAPTIVE_STEP_SIZE				; Yes, so start with minimum stepsize (scale)
	add		r1, #1
	strb	r10, [r12, #(sb_adpcm_reference-sb_mode)]	; Save the reference byte
	str		r1, [r12, #(sb_buffer_start-sb_mode)]		; Save new input sample start address
	mov		r1, #0
	strb	r1, [r12, #(sb_adpcm_haveref-sb_mode)]		; haveref = 0
	strb	r11,[r12, #(sb_adpcm_stepsize-sb_mode)]		; Save the stepsize (scale) value
	;------
	; Flow-thru to fill the buffer!
	;------
	;=======
	; We are currently playing a 2-bit ADPCM buffer, so refill buffer and continue playing.
	;=======
sb_9_play_adpcm26
	ldr		r1, [r12, #(sb_buffer_start-sb_mode)]		; t1 = input sample start address
	ldr		r2, [r12, #(sb_buffer_end-sb_mode)]			; t2 = sb_buffer_end (for total buffer size)
	ldr		r3, [r12, #(sb_buffer_position-sb_mode)]	; t3 = input buffer position (16.16 fixed point)
	ldr		r4, [r12, #(sb_buffer_increment-sb_mode)]	; t4 = input buffer incrementer (16.16 fixed point)
	ldrb	r10, [r12, #(sb_adpcm_reference-sb_mode)]	; Use the current saved reference byte
	ldrsb	r11, [r12, #(sb_adpcm_stepsize-sb_mode)]	; Load current stepsize (scale) value
	ldr		r9, =scaleMap26
	;------
	; First we need to decode a sufficient number of samples
	; into the adpcm_buf buffer. Decode up to ADPCM_BUF_SIZE samples.
	;------
	push	{r0, r5}
	sub		r0, r12, #ADPCM_BUF_SIZE					; Point r0 to the ADPCM buffer
	add		lr, r9, #40									; lr = adjustMap address
2	mov		r7, r3, lsr #16								; r7 = current integral buffer position value
4	add		r6, r1, r3, lsr #16							; r6 = buffer_start + 16.16 fixed point buffer position
	cmp		r6, r2	
	bge		sb_adpcm_decode_done						; All done if we run out of input buffer
	sub		r5, #3
	add		r3, r4										; Add incrementer to the buffer position
	cmp		r7, r3, lsr #16								; Did the integral input position change?
	beq		%b4											; Skip ADPCM sample decoding if not yet
	;=======
	; MixTemp[done++]=decode_ADPCM_3_sample((sb.dma.buf.b8[i] >> 5) & 0x7,sb.adpcm.reference,sb.adpcm.stepsize);
	;=======
	ldrb	r8, [r6]									; Get the input byte (3xADPCM samples)
	calc_adpcm_sample 40, 5								; Adjusts r10 & r11, destroys r7
	;=======
	; MixTemp[done++]=decode_ADPCM_3_sample((sb.dma.buf.b8[i] >> 2) & 0x7,sb.adpcm.reference,sb.adpcm.stepsize);
	;=======
	and		r8, #0x1F
	calc_adpcm_sample 40, 2								; Adjusts r10 & r11, destroys r7
	;=======
	; MixTemp[done++]=decode_ADPCM_3_sample((sb.dma.buf.b8[i] & 0x3) << 1,sb.adpcm.reference,sb.adpcm.stepsize);
	;=======
	and		r8, #0x3
	lsl		r8, #1
	calc_adpcm_sample 40, 0								; Adjusts r10 & r11, destroys r7
	;------
	; Back to loop until we run out of output buffer.
	;------
	cmp		r5, #0										; Out of output buffer?
	bge		%b2											; Not yet, back to loop
	b		sb_adpcm_decode_done

sb_10_start_silence
	ldr		r1, [r12, #(sb_request_pointer-sb_mode)]	; t1 = sb_request_pointer
	ldr		r2, [r12, #(sb_dma_total-sb_mode)]			; t2 = sb_dma_total
	ldr		r4, [r12, #(sb_request_increment-sb_mode)]	; t4 = sb_request_increment (16.16 fixed point)
	movs	r3, r2, lsl #16								; r3 = end 16.16 position (for short buffer)
	subeq	r2, #1										; If we are to play 65536 samples, play only 65535
	cmp		r2, #4										; Are we to play < 4 samples?
	add		r2, r1										; t2 = end address of the input buffer
	str		r1, [r12, #(sb_buffer_start-sb_mode)]		; Remember the start address of this DMA transfer
	str		r2, [r12, #(sb_buffer_end-sb_mode)]
	mov		r6, #0
	str		r6, [r12, #(sb_buffer_position-sb_mode)]	; Clear the 16.16 fixed point position
	str		r4, [r12, #(sb_buffer_increment-sb_mode)]
	blt		samples_copied								; If buffer < 4, jump directly to end.
	;------
	; Mark that we are currently playing
	;------
	mov		r1, #SB_PLAY_SILENCE
	strb	r1, [r12]
	;------
	; Flow-thru to fill the output buffer!
	;------
sb_11_play_silence
	ldr		r1, [r12, #(sb_buffer_start-sb_mode)]
	ldr		r2, [r12, #(sb_buffer_end-sb_mode)]
	ldr		r3, [r12, #(sb_buffer_position-sb_mode)]	; t3 = input buffer position (16.16 fixed point)
	ldr		r4, [r12, #(sb_buffer_increment-sb_mode)]	; t4 = input buffer incrementer (16.16 fixed point)
	;------
	; Copy audio_samples_per_trans worth of samples.
	;------
1	add		r3, r4									; Increment the 16.16 sample pointer	
	;-------
	; Check the output buffer remaining length
	;-------
	subs	r5, #1
	blt		%f1
	;-------
	; Check the input buffer remaining length
	;-------
	add		r7, r1, r3, lsr #16
	cmp		r7, r2
	blt		%b1
	;-------
	; Done, we ran out of either input or output buffer.
	;-------
1	addlt	r5, #1									; If we stopped because of output buffer end, restore r5
	;------
	; Save the new buffer position
	;------
	b		samples_copied

	;-------
	; Play Direct DAC audio.
	; Input:
	;	r0  = output buffer pointer
	;	r5  = number of 32kHz samples to generate
	;	r12 = pointer to sb_mode
	;-------
sb_14_play_direct
	ldr		r4, =DirectDACIncr
	ldr		r10, [r12, #(sb_dac_write-sb_mode)]
	ldr		r3, [r12, #(sb_dac_read-sb_mode)]
	ldr		r4, [r4]								; r4 = incrementer based on timer frequency
	sub		r1, r12, #(ADPCM_BUF_SIZE+DAC_BUF_SIZE)	; r1 = DAC buffer start (input buffer)
	;-------
	; Loop here playing the samples in DAC buffer
	;-------
1	lsr		r6, r3, #16
	ldrb	r6, [r1, r6]							; Get one sample byte
	cmp		r10, r3, lsr #16
	addne	r3, r4									; Increment the 16.16 sample pointer	
	ldrh	r7, [r0]								; Get current sample from output buffer (AdLib sample)
	bic		r3, #(DAC_BUF_SIZE<<16)
	sub		r6, #0x80
	lsl		r6, #7									; r6 = 16-bit signed sample from the 8-bit SB sample buffer
	;-------
	; Check the output buffer remaining length
	;-------
	subs	r5, #1
	blt		%f1
	;-------
	; Mix the sample to the output buffer
	;-------
	qadd16	r7, r7, r6								; Mix the SB sample to the AdLib buffer
	strh	r7, [r0], #2							; Write the mixed output sample
	b		%b1
	;-------
	; Done, we ran out of either input or output buffer.
	;-------
1	addlt	r5, #1									; If we stopped because of output buffer end, restore r5
	cmp		r10, r3, lsr #16
	moveq	r6, #0									; If we ran out of input ...
	strbeq	r6, [r12]								; ... go to idle mode.
	str		r3, [r12, #(sb_dac_read-sb_mode)]		; Save new read position
	b		sb_done
	

	AREA sb_DATA, DATA, READWRITE
	ALIGN	4

	;=======
	; ADPCM sample handlers
	;=======
	
scaleMap4		; 64 bytes
	DCB	0,  1,  2,  3,  4,  5,  6,  7,  0,  -1,  -2,  -3,  -4,  -5,  -6,  -7
	DCB	1,  3,  5,  7,  9, 11, 13, 15, -1,  -3,  -5,  -7,  -9, -11, -13, -15
	DCB	2,  6, 10, 14, 18, 22, 26, 30, -2,  -6, -10, -14, -18, -22, -26, -30
	DCB	4, 12, 20, 28, 36, 44, 52, 60, -4, -12, -20, -28, -36, -44, -52, -60
adjustMap4		; 64 bytes
	DCB	  0, 0, 0, 0, 0, 16, 16, 16
	DCB	  0, 0, 0, 0, 0, 16, 16, 16
	DCB	240, 0, 0, 0, 0, 16, 16, 16
	DCB	240, 0, 0, 0, 0, 16, 16, 16
	DCB	240, 0, 0, 0, 0, 16, 16, 16
	DCB	240, 0, 0, 0, 0, 16, 16, 16
	DCB	240, 0, 0, 0, 0,  0,  0,  0
	DCB	240, 0, 0, 0, 0,  0,  0,  0

scaleMap2		; 24 bytes
	DCB	0,  1,  0,  -1, 1,  3,  -1,  -3
	DCB	2,  6, -2,  -6, 4, 12,  -4, -12
	DCB	8, 24, -8, -24, 6, 48, -16, -48
adjustMap2		; 24 bytes
	DCB	  0, 4,   0, 4
	DCB	252, 4, 252, 4, 252, 4, 252, 4
	DCB	252, 4, 252, 4, 252, 4, 252, 4
	DCB	252, 0, 252, 0

scaleMap26		; 40 bytes
	DCB	0,  1,  2,  3,  0,  -1,  -2,  -3
	DCB	1,  3,  5,  7, -1,  -3,  -5,  -7
	DCB	2,  6, 10, 14, -2,  -6, -10, -14
	DCB	4, 12, 20, 28, -4, -12, -20, -28
	DCB	5, 15, 25, 35, -5, -15, -25, -35
adjustMap26	; 40 bytes
	DCB	  0, 0, 0, 8,   0, 0, 0, 8
	DCB	248, 0, 0, 8, 248, 0, 0, 8
	DCB	248, 0, 0, 8, 248, 0, 0, 8
	DCB	248, 0, 0, 8, 248, 0, 0, 8
	DCB	248, 0, 0, 0, 248, 0, 0, 0

	;======
	; Frequency divider lookup table
	;======
	
	MACRO
	buildlut $from, $to
		DCD   2048000 / (256 - ($from))
		IF $to <> $from
			buildlut $from+1, $to
		ENDIF
	MEND
	
sb_incr_table
	buildlut 0, 63
	buildlut 64, 127
	buildlut 128, 191
	buildlut 192, 255

	END