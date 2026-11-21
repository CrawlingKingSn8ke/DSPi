#include "recipe.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>
static bool number(const char *s,double *v) {
    char *end; *v=strtod(s,&end); return end!=s && !*end && isfinite(*v);
}
static bool same_name(const char *a,const char *b){
    while(*a&&*b){if(tolower((unsigned char)*a++)!=tolower((unsigned char)*b++))return false;}return *a==*b;
}
#include "effects_cli.h"
static int tube_named(const char *name){
    static const char *names[]={"custom","12ax7","5751","12at7","12ay7","12au7","6sn7","6sl7","6dj8","ef86","6sj7","el84","el34","6l6","6v6","kt88","300b"};
    for(unsigned i=0;i<=16;i++)if(same_name(name,names[i]))return (int)i;
    double v;if(number(name,&v)&&v>=0&&v<=16&&floor(v)==v)return (int)v;
    return -1;
}
/* Returns -1 invalid, 0 unrelated flag, 1 applied. All fields are validated
 * transactionally by the graph setter before changing live configuration. */
static int configure_tube(const char *flag,int argc,char **argv,int *index,DspiGraph *g,unsigned mask){
    if(strncmp(flag,"--tube",6))return 0;
    int i=*index;TubeConfig c=g->tube;double value;
    if(!strcmp(flag,"--tube")){
        if(i+2>=argc)return -1;
        int style=tube_named(argv[i++]);double drive,mix;
        if(style<0||!number(argv[i++],&drive)||!number(argv[i++],&mix)||!dspi_tube_style(&c,(unsigned)style))return -1;
        c.enabled=true;c.output_mask|=(uint16_t)mask;c.drive_db=(float)drive;c.mix_pct=(float)mix;
    }else if(!strcmp(flag,"--tube-off")){
        c.output_mask&=(uint16_t)~mask;c.enabled=c.output_mask!=0;
    }else if(!strcmp(flag,"--tube-no-output-stage"))c.xfmr_enabled=false;
    else if(!strcmp(flag,"--tube-output-stage")){
        double damping,res;
        if(i+1>=argc||!number(argv[i++],&damping)||!number(argv[i++],&res))return -1;
        c.xfmr_enabled=true;c.xfmr_damping=(float)damping;c.xfmr_res_hz=(float)res;
    }else if(!strcmp(flag,"--tube-rectifier")){
        if(i>=argc)return -1;
        static const char *names[]={"solid-state","gz34","5u4","5y3"};int rect=-1;
        for(unsigned r=0;r<4;r++)if(same_name(argv[i],names[r]))rect=(int)r;
        i++;if(rect<0)return -1;c.rectifier=(uint8_t)rect;
    }else{
        if(i>=argc||!number(argv[i++],&value))return -1;
        float v=(float)value;
        if(!strcmp(flag,"--tube-drive"))c.drive_db=v;
        else if(!strcmp(flag,"--tube-mix"))c.mix_pct=v;
        else if(!strcmp(flag,"--tube-trim"))c.trim_db=v;
        else if(!strcmp(flag,"--tube-bias")){if(c.bias_pct!=v)c.tube_type=0;c.bias_pct=v;}
        else if(!strcmp(flag,"--tube-asym")){if(c.asym_db!=v)c.tube_type=0;c.asym_db=v;}
        else if(!strcmp(flag,"--tube-hardness")){if(c.hardness_pct!=v)c.tube_type=0;c.hardness_pct=v;}
        else if(!strcmp(flag,"--tube-sag")){if(c.sag_pct!=v)c.tube_type=0;c.sag_pct=v;}
        else return -1;
    }
    if(!dspi_graph_tube(g,&c))return -1;*index=i;return 1;
}
static int configure_limiter(const char *flag,int argc,char **argv,int *index,DspiGraph *g,unsigned mask){
    if(strncmp(flag,"--limiter",9))return 0;
    int i=*index,operation;double first=0,second=0;
    if(!strcmp(flag,"--limiter")){
        operation=0;if(i+1>=argc||!number(argv[i++],&first)||!number(argv[i++],&second))return -1;
    }else if(!strcmp(flag,"--limiter-off"))operation=1;
    else{
        if(i>=argc||!number(argv[i++],&first))return -1;
        if(!strcmp(flag,"--limiter-link")){operation=2;if(first<0||first>LIMITER_LINK_GROUP_MAX||floor(first)!=first)return -1;}
        else if(!strcmp(flag,"--limiter-threshold"))operation=3;
        else if(!strcmp(flag,"--limiter-release"))operation=4;
        else return -1;
    }
    for(unsigned o=0;o<g->outputs;o++)if(mask&(1u<<o)){
        LimiterOutputConfig c;if(!dspi_limiter_get(g->limiter,o,&c))return -1;
        if(operation==0){c.enabled=true;c.threshold_db=(float)first;c.release_ms=(float)second;}
        else if(operation==1)c.enabled=false;
        else if(operation==2)c.link_group=(uint8_t)first;
        else if(operation==3)c.threshold_db=(float)first;
        else c.release_ms=(float)first;
        if(!dspi_graph_limiter(g,o,&c))return -1;
    }
    *index=i;return 1;
}
static int type_named(const char *s,bool crossover) {
    static const char *peq[]={"flat","peak","low-shelf","high-shelf","low-pass","high-pass",
        "notch","all-pass","all-pass1","low-shelf1","high-shelf1","lt","low-pass1","high-pass1"};
    static const char *xo[]={"lr2-lp","lr2-hp","lr4-lp","lr4-hp","lr6-lp","lr6-hp","lr8-lp","lr8-hp",
        "bw1-lp","bw1-hp","bw2-lp","bw2-hp","bw3-lp","bw3-hp","bw4-lp","bw4-hp",
        "bw5-lp","bw5-hp","bw6-lp","bw6-hp","bw7-lp","bw7-hp","bw8-lp","bw8-hp",
        "bes2-lp","bes2-hp","bes4-lp","bes4-hp","bes6-lp","bes6-hp","bes8-lp","bes8-hp"};
    unsigned n=crossover?32:14;
    for(unsigned i=0;i<n;i++) if(!strcmp(s,crossover?xo[i]:peq[i]))return (int)i+(crossover?32:0);
    return -1;
}
static bool index_arg(const char *s,unsigned count,unsigned *index) {
    double v;if(!number(s,&v)||v<1||v>count||floor(v)!=v)return false;
    *index=(unsigned)v-1;return true;
}
static int selected_pairs(unsigned outputs,unsigned mask){
    unsigned pairs=0;
    for(unsigned p=0;p<outputs/2;p++){
        unsigned bits=(mask>>(2*p))&3u;
        if(bits==1||bits==2)return -1;
        if(bits==3)pairs|=1u<<p;
    }
    return (int)pairs;
}
static int configure_crossfeed(const char *flag,int argc,char **argv,int *index,DspiGraph *g,unsigned mask){
    if(strncmp(flag,"--crossfeed",11))return 0;
    CrossfeedConfig c=g->crossfeed;int i=*index;
    if(!strcmp(flag,"--crossfeed-itd")){
        if(i>=argc)return -1;
        if(same_name(argv[i],"on"))c.itd_enabled=true;
        else if(same_name(argv[i],"off"))c.itd_enabled=false;
        else return -1;i++;
    }else{
        int pairs=selected_pairs(g->outputs,mask);if(pairs<=0)return -1;
        if(!strcmp(flag,"--crossfeed-off")){
            c.output_pair_mask&=(uint8_t)~pairs;c.enabled=c.output_pair_mask!=0;
        }else{
            if(!strcmp(flag,"--crossfeed")){
                if(i>=argc)return -1;const char *name=argv[i++];
                if(same_name(name,"default"))c.preset=CROSSFEED_PRESET_DEFAULT;
                else if(same_name(name,"chumoy")||same_name(name,"chu-moy"))c.preset=CROSSFEED_PRESET_CHUMOY;
                else if(same_name(name,"meier")||same_name(name,"jan-meier"))c.preset=CROSSFEED_PRESET_MEIER;
                else return -1;
            }else if(!strcmp(flag,"--crossfeed-custom")){
                double fc,feed;
                if(i+1>=argc||!number(argv[i++],&fc)||!number(argv[i++],&feed))return -1;
                c.preset=CROSSFEED_PRESET_CUSTOM;c.custom_fc=(float)fc;c.custom_feed_db=(float)feed;
            }else return -1;
            c.enabled=true;c.output_pair_mask|=(uint8_t)pairs;
        }
    }
    if(!dspi_graph_crossfeed(g,&c))return -1;*index=i;return 1;
}
unsigned dspi_recipe_output_count(int argc,char **argv,unsigned inputs) {
    unsigned outputs=inputs;bool found=false;
    for(int i=3;i<argc;i++)if(!strcmp(argv[i],"--outputs")){
        unsigned index;
        if(found||i+1>=argc||!index_arg(argv[++i],DSPI_MAX_CHANNELS,&index))return 0;
        outputs=index+1;found=true;
    }
    return outputs;
}
bool dspi_recipe_configure(int argc,char **argv,DspiGraph *graph) {
    unsigned count=graph->outputs;
    DspiChannel *channels=graph->channel;
    unsigned mask=(1u<<count)-1,peq_count[DSPI_MAX_CHANNELS]={0},xo_count[DSPI_MAX_CHANNELS]={0};
    unsigned input_mask=(1u<<graph->inputs)-1,input_peq_count[DSPI_MAX_CHANNELS]={0};
    if(argc==6 && strncmp(argv[3],"--",2)) {
        double hz,q,gain;
        if(!number(argv[3],&hz)||!number(argv[4],&q)||!number(argv[5],&gain)||q<0.1||q>100)return false;
        for(unsigned c=0;c<count;c++) if(!dspi_set_peq(&channels[c],0,FILTER_PEAKING,(float)hz,(float)q,(float)gain,0,false))return false;
        return true;
    }
    bool added=false;
    for(int i=3;i<argc;) {
        const char *flag=argv[i++];
        if(!strcmp(flag,"--input-channel")){
            if(i>=argc)return false;const char *s=argv[i++];unsigned input;
            if(!strcmp(s,"all")||!strcmp(s,"both"))input_mask=(1u<<graph->inputs)-1;
            else if(!strcmp(s,"left"))input_mask=1;
            else if(!strcmp(s,"right")&&graph->inputs>=2)input_mask=2;
            else if(index_arg(s,graph->inputs,&input))input_mask=1u<<input;
            else return false;
            continue;
        }
        if(!strcmp(flag,"--preamp")||!strcmp(flag,"--input-preamp")||!strcmp(flag,"--input-delay")||!strcmp(flag,"--input-eq-clear")){
            bool preamp=!strcmp(flag,"--preamp")||!strcmp(flag,"--input-preamp"),clear=!strcmp(flag,"--input-eq-clear");double v=0;
            if(!clear&&(i>=argc||!number(argv[i++],&v)))return false;
            for(unsigned input=0;input<graph->inputs;input++)if(input_mask&(1u<<input)){
                bool ok=preamp?dspi_graph_input_preamp(graph,input,(float)v):clear?dspi_graph_input_eq_clear(graph,input):dspi_graph_input_delay(graph,input,(float)v);
                if(!ok)return false;if(clear)input_peq_count[input]=0;
            }
            added=true;continue;
        }
        if(!strcmp(flag,"--input-peak")||!strcmp(flag,"--input-filter")||!strcmp(flag,"--input-lt")){
            bool lt=!strcmp(flag,"--input-lt");int type=lt?FILTER_LINKWITZ_TRANSFORM:FILTER_PEAKING;double hz,q,gain,target=0;
            if(!strcmp(flag,"--input-filter")){if(i>=argc)return false;type=type_named(argv[i++],false);if(type<0)return false;}
            if(i+2>=argc||!number(argv[i++],&hz)||!number(argv[i++],&q)||!number(argv[i++],&gain))return false;
            if(lt&&(i>=argc||!number(argv[i++],&target)))return false;
            for(unsigned input=0;input<graph->inputs;input++)if(input_mask&(1u<<input)){
                if(!dspi_graph_input_eq(graph,input,input_peq_count[input]++,(uint8_t)type,(float)hz,(float)q,(float)gain,(float)target,false))return false;
            }
            added=true;continue;
        }
        int effect=configure_effects(flag,argc,argv,&i,graph,mask);
        if(effect<0)return false;if(effect>0){added=true;continue;}
        int limiter=configure_limiter(flag,argc,argv,&i,graph,mask);
        if(limiter<0)return false;if(limiter>0){added=true;continue;}
        int tube=configure_tube(flag,argc,argv,&i,graph,mask);
        if(tube<0)return false;if(tube>0){added=true;continue;}
        int crossfeed=configure_crossfeed(flag,argc,argv,&i,graph,mask);
        if(crossfeed<0)return false;if(crossfeed>0){added=true;continue;}
        if(!strcmp(flag,"--outputs")){unsigned index;if(i>=argc||!index_arg(argv[i++],DSPI_MAX_CHANNELS,&index)||index+1!=graph->outputs)return false;added=true;continue;}
        if(!strcmp(flag,"--clear-routes")){dspi_graph_clear_routes(graph);added=true;continue;}
        if(!strcmp(flag,"--volume")){
            double db;
            if(i>=argc||!number(argv[i++],&db)||!dspi_graph_volume(graph,(float)db))return false;
            added=true;continue;
        }
        if(!strcmp(flag,"--master-gain")){
            double db;if(i>=argc||!number(argv[i++],&db)||!dspi_graph_master_gain(graph,(float)db))return false;
            added=true;continue;
        }
        if(!strcmp(flag,"--loudness")||!strcmp(flag,"--loudness-off")){
            double ref=graph->reference_spl,intensity=graph->intensity;
            bool enabled=!strcmp(flag,"--loudness");
            if(enabled&&(i+1>=argc||!number(argv[i++],&ref)||!number(argv[i++],&intensity)))return false;
            uint8_t active=enabled?(uint8_t)(graph->loudness_mask|mask):(uint8_t)(graph->loudness_mask&~mask);
            if(!dspi_graph_loudness(graph,(float)ref,(float)intensity,active))return false;
            added=true;continue;
        }
        if(!strcmp(flag,"--route")||!strcmp(flag,"--route-invert")||!strcmp(flag,"--route-off")){
            bool enabled=strcmp(flag,"--route-off")!=0,invert=!strcmp(flag,"--route-invert");
            unsigned input,output;double db=0;
            if(i+1>=argc||!index_arg(argv[i++],dspi_graph_sources(graph),&input)||!index_arg(argv[i++],count,&output))return false;
            if(enabled&&(i>=argc||!number(argv[i++],&db)))return false;
            if(!dspi_graph_route(graph,input,output,(float)db,invert,enabled))return false;
            added=true;continue;
        }
        if(!strcmp(flag,"--pair")){
            unsigned pair;
            if(i>=argc||!index_arg(argv[i++],count/2,&pair))return false;
            mask=3u<<(2*pair);continue;
        }
        if(!strcmp(flag,"--channel")) {
            if(i>=argc)return false;
            const char *s=argv[i++];
            unsigned index;
            if(!strcmp(s,"both")||!strcmp(s,"all"))mask=(1u<<count)-1;
            else if(!strcmp(s,"left"))mask=1;
            else if(!strcmp(s,"right")&&count>=2)mask=2;
            else if(index_arg(s,count,&index))mask=1u<<index;
            else return false;
            continue;
        }
        if(!strcmp(flag,"--gain")||!strcmp(flag,"--delay")||!strcmp(flag,"--mute")||!strcmp(flag,"--unmute")){
            bool gain=!strcmp(flag,"--gain"),delay=!strcmp(flag,"--delay");double v=0;
            if((gain||delay)&&(i>=argc||!number(argv[i++],&v)))return false;
            for(unsigned c=0;c<count;c++)if(mask&(1u<<c)){
                bool ok=gain?dspi_graph_gain(graph,c,(float)v):delay?dspi_graph_delay(graph,c,(float)v):
                    dspi_graph_mute(graph,c,!strcmp(flag,"--mute"));
                if(!ok)return false;
            }
            added=true;continue;
        }
        bool crossover=!strcmp(flag,"--crossover");
        bool lt=!strcmp(flag,"--lt");int type=lt?FILTER_LINKWITZ_TRANSFORM:FILTER_PEAKING;
        if(crossover || !strcmp(flag,"--filter")) {
            if(i>=argc)return false;
            type=type_named(argv[i++],crossover);
            if(type<0)return false;
        } else if(strcmp(flag,"--peak")&&!lt)return false;
        double hz,q=0.707,gain=0,target=0;
        if(i>=argc || !number(argv[i++],&hz))return false;
        if(!crossover) {
            if(i+1>=argc || !number(argv[i++],&q)||!number(argv[i++],&gain))return false;
        }
        if(lt&&(i>=argc||!number(argv[i++],&target)))return false;
        for(unsigned c=0;c<count;c++) if(mask&(1u<<c)) {
            if(crossover) {
                if(!dspi_set_crossover(&channels[c],xo_count[c]++,(uint8_t)type,(float)hz,false))return false;
            } else if(!dspi_set_peq(&channels[c],peq_count[c]++,(uint8_t)type,(float)hz,(float)q,(float)gain,(float)target,false))return false;
        }
        added=true;
    }
    return added;
}
