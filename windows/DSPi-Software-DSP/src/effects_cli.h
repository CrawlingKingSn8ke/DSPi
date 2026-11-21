/* GPL-3.0. Included after WAV parser helpers; all configuration is offline. */
static bool on_off(const char *s,bool *v){if(same_name(s,"on"))*v=true;else if(same_name(s,"off"))*v=false;else return false;return true;}
static int upmix_mode(const char *s,bool center){
    if(same_name(s,"off"))return center?UPMIX_CENTER_OFF:UPMIX_SURROUND_OFF;
    if(same_name(s,"passive"))return center?UPMIX_CENTER_PASSIVE:UPMIX_SURROUND_PASSIVE;
    if(same_name(s,"adaptive"))return center?UPMIX_CENTER_ADAPTIVE:UPMIX_SURROUND_ADAPTIVE;
    return -1;
}
static int configure_effects(const char *flag,int argc,char **argv,int *index,DspiGraph *g,unsigned mask){
    int i=*index;double v[5];
    if(!strncmp(flag,"--psybass",9)){
        PsybassConfig c=g->psybass;
        if(!strcmp(flag,"--psybass")){
            if(i+4>=argc)return -1;
            for(unsigned k=0;k<5;k++)if(!number(argv[i++],&v[k]))return -1;
            c.enabled=true;c.output_mask|=(uint16_t)mask;
            c.cutoff_hz=(float)v[0];c.harmonics_db=(float)v[1];c.drive_db=(float)v[2];c.character_pct=(float)v[3];c.original_db=(float)v[4];
        }else if(!strcmp(flag,"--psybass-off")){c.output_mask&=(uint16_t)~mask;c.enabled=c.output_mask!=0;}
        else return -1;
        if(!dspi_graph_psybass(g,&c))return -1;
    }else if(!strncmp(flag,"--subharm",9)){
        SubharmConfig c=g->subharm;
        if(!strcmp(flag,"--subharm")){
            if(i+3>=argc)return -1;
            for(unsigned k=0;k<4;k++)if(!number(argv[i++],&v[k]))return -1;
            c.enabled=true;c.output_mask|=(uint16_t)mask;c.low_db=(float)v[0];c.high_db=(float)v[1];c.top_db=(float)v[2];c.boost_db=(float)v[3];
        }else if(!strcmp(flag,"--subharm-off")){c.output_mask&=(uint16_t)~mask;c.enabled=c.output_mask!=0;}
        else if(!strcmp(flag,"--subharm-select")){
            if(i+2>=argc)return -1;
            if(same_name(argv[i],"all"))c.select_mode=0;
            else if(same_name(argv[i],"percussive"))c.select_mode=1;
            else if(same_name(argv[i],"sustained"))c.select_mode=2;
            else return -1;i++;
            if(!number(argv[i++],&v[0])||!number(argv[i++],&v[1]))return -1;
            c.select_depth=(float)v[0];c.select_hold_ms=(float)v[1];
        }else if(!strcmp(flag,"--subharm-link")){if(i>=argc||!on_off(argv[i++],&c.link_pairs))return -1;}
        else if(!strcmp(flag,"--subharm-solo")){if(i>=argc||!on_off(argv[i++],&c.solo))return -1;}
        else if(!strcmp(flag,"--subharm-ceiling")){if(i>=argc||!number(argv[i++],&v[0]))return -1;c.ceiling_db=(float)v[0];}
        else return -1;
        if(!dspi_graph_subharm(g,&c))return -1;
    }else if(!strncmp(flag,"--leveller",10)){
        LevellerConfig c=g->leveller;
        if(!strcmp(flag,"--leveller")){
            if(i+2>=argc||!number(argv[i++],&v[0]))return -1;
            if(same_name(argv[i],"slow"))c.speed=0;
            else if(same_name(argv[i],"medium"))c.speed=1;
            else if(same_name(argv[i],"fast"))c.speed=2;
            else return -1;i++;
            if(!number(argv[i++],&v[1]))return -1;
            c.enabled=true;c.amount=(float)v[0];c.max_gain_db=(float)v[1];
        }else if(!strcmp(flag,"--leveller-off"))c.enabled=false;
        else if(!strcmp(flag,"--leveller-lookahead")){if(i>=argc||!on_off(argv[i++],&c.lookahead))return -1;}
        else {
            if(i>=argc||!number(argv[i++],&v[0]))return -1;
            if(!strcmp(flag,"--leveller-gate"))c.gate_threshold_db=(float)v[0];
            else if(!strcmp(flag,"--leveller-detectors")||!strcmp(flag,"--leveller-apply")){
                if(v[0]<0||v[0]>255||floor(v[0])!=v[0])return -1;
                if(!strcmp(flag,"--leveller-detectors"))c.detector_mask=(uint8_t)v[0];else c.apply_mask=(uint8_t)v[0];
            }else return -1;
        }
        if(!dspi_graph_leveller(g,&c))return -1;
    }else if(!strncmp(flag,"--upmix",7)){
        UpmixConfig c=g->upmix;
        if(!strcmp(flag,"--upmix-off"))c.enabled=false;
        else if(!strcmp(flag,"--upmix")){
            if(i>=argc)return -1;int cm=upmix_mode(argv[i],true),sm=upmix_mode(argv[i++],false);
            if(cm<0||sm<0||cm==UPMIX_CENTER_OFF)return -1;
            c.enabled=true;c.center_mode=(uint8_t)cm;c.surround_mode=(uint8_t)sm;
        }else if(!strcmp(flag,"--upmix-center")||!strcmp(flag,"--upmix-surround")){
            if(i>=argc)return -1;bool center=!strcmp(flag,"--upmix-center");int mode=upmix_mode(argv[i++],center);if(mode<0)return -1;
            if(center)c.center_mode=(uint8_t)mode;else c.surround_mode=(uint8_t)mode;
        }else{
            if(i>=argc||!number(argv[i++],&v[0]))return -1;float f=(float)v[0];
            if(!strcmp(flag,"--upmix-strength"))c.strength_pct=f;
            else if(!strcmp(flag,"--upmix-width"))c.center_width_pct=f;
            else if(!strcmp(flag,"--upmix-threshold"))c.corr_threshold_pct=f;
            else if(!strcmp(flag,"--upmix-attack"))c.attack_ms=f;
            else if(!strcmp(flag,"--upmix-release"))c.release_ms=f;
            else if(!strcmp(flag,"--upmix-detector-hpf"))c.detector_hpf_hz=f;
            else if(!strcmp(flag,"--upmix-delay"))c.surround_delay_ms=f;
            else if(!strcmp(flag,"--upmix-hpf"))c.surround_hpf_hz=f;
            else if(!strcmp(flag,"--upmix-lpf"))c.surround_lpf_hz=f;
            else if(!strcmp(flag,"--upmix-decorr"))c.decorr_pct=f;
            else if(!strcmp(flag,"--upmix-presence"))c.presence_db=f;
            else return -1;
        }
        if(!dspi_graph_upmix(g,&c))return -1;
    }else return 0;
    *index=i;return 1;
}
