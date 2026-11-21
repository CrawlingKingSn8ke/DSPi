/* GPL-3.0. Standalone DSPi APO identities and isolated-test control contract. */
#ifndef DSPI_APO_H
#define DSPI_APO_H
#define COBJMACROS
#include <windows.h>
#include <audioenginebaseapo.h>
static const CLSID CLSID_DspiApo = {0xe53f75ef,0x9901,0x4ec4,{0xa8,0xd1,0x2f,0xe2,0x60,0x6a,0x74,0x31}};
static const IID DSPI_IID_APO = {0xfd7f2b29,0x24d0,0x4b5c,{0xb1,0x77,0x59,0x2c,0x39,0xf9,0xca,0x10}};
static const IID DSPI_IID_CONFIG = {0x0e5ed805,0xaba6,0x49c3,{0x8f,0x9a,0x2b,0x8c,0x88,0x9c,0x4f,0xa8}};
static const IID DSPI_IID_RT = {0x9e1d6a6d,0xddbc,0x4e95,{0xa4,0xc7,0xad,0x64,0xba,0x37,0x84,0x6c}};
/* IAudioSystemEffects from audioenginebaseapo.h. */
static const IID DSPI_IID_FX = {0x5fa00f27,0xadd6,0x499a,{0x8a,0x9d,0x6b,0x98,0x52,0x1f,0xa7,0x5b}};
static const IID DSPI_IID_CONTROL = {0x27e2ff4b,0x1280,0x45e8,{0xa3,0x32,0x9e,0xe4,0xca,0x14,0x48,0xcd}};
static const GUID DSPI_FLOAT = {3,0,0x0010,{0x80,0,0,0xaa,0,0x38,0x9b,0x71}};
typedef struct DspiApoControl DspiApoControl;
typedef struct {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(DspiApoControl*,REFIID,void**);
    ULONG (STDMETHODCALLTYPE *AddRef)(DspiApoControl*);
    ULONG (STDMETHODCALLTYPE *Release)(DspiApoControl*);
    /* Bounded UTF-8 native recipe, copied before locking; no IPC/path support. */
    HRESULT (STDMETHODCALLTYPE *SetRecipe)(DspiApoControl*,const char*);
    HRESULT (STDMETHODCALLTYPE *BindProfile)(DspiApoControl*,const wchar_t *root,const wchar_t *key);
} DspiApoControlVtbl;
struct DspiApoControl {const DspiApoControlVtbl *lpVtbl;};
#endif
