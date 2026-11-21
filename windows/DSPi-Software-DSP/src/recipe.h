#ifndef DSPI_RECIPE_H
#define DSPI_RECIPE_H
#include "graph.h"
unsigned dspi_recipe_output_count(int argc,char **argv,unsigned inputs);
bool dspi_recipe_configure(int argc,char **argv,DspiGraph *graph);
#endif
