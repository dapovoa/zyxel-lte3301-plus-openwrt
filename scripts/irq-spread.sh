#!/bin/sh
set_irq(){ n=$(grep "$1" /proc/interrupts | cut -d: -f1 | tr -d " "); [ -n "$n" ] && echo $2 > /proc/irq/$n/smp_affinity; }
set_irq "ethernet" 1; set_irq "xhci-hcd" 2; set_irq "mt7615e" 4
