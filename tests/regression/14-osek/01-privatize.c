// PARAM: --oil example.oil -I defaultAppWorkstation/


#include "defaultAppWorkstation/tpl_os_generated_configuration.h"

int x;
int y;
int z;
int t;

ISR( ii ) {
   x = 1;
   return;
}


ISR( i) {
   GetResource(r);
   x++;
   x--;
   ReleaseResource(r);
   return;
}

TASK(t) {
   y=0;
   x=1;
   y=x;
return;}
