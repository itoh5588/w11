VBOM_all = sys_w11a_dma_test_as7.vbom sys_w11a_dma_as7.vbom \
           sys_w11a_rp07_as7.vbom sys_w11a_rp07w_as7.vbom \
           sys_w11a_sa_as7.vbom
BIT_all  = $(VBOM_all:.vbom=.bit)

include ${RETROBASE}/rtl/make_viv/viv_default_artys7.mk

.PHONY : all clean
all : $(BIT_all)
clean : viv_clean

include ${RETROBASE}/rtl/make_viv/generic_vivado.mk

ifndef DONTINCDEP
include $(VBOM_all:.vbom=.dep_vsyn)
endif
