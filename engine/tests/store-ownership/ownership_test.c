/*
 * ownership_test: what Forza Horizon 6 asks the Xbox runtime (xgameruntime) about the player's add-ons and profile,
 * asked the same way, through the runtime's own interfaces (QueryApiImpl), against fake_service.py. No game, no
 * account, no credentials.
 *
 * It lists, as the in-game store does, the game's add-ons and which of them the account owns
 * (XStoreQueryAssociatedProductsAsync), the entitled products (XStoreQueryEntitledProductsAsync), the add-on licences
 * (XStoreQueryAddOnLicensesAsync: the VIP membership, the Car Pass) and the gamer picture in its four sizes
 * (XUserGetGamerPictureAsync). One line per fact, for check.py. Built with llvm-mingw against the runtime's generated
 * headers; see README.md.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#define COBJMACROS
#include <windows.h>
#include <stdio.h>
#include <initguid.h>
#include "xasyncprovider.h"
#include "xuser.h"
#include "xstore.h"

typedef HRESULT (WINAPI *query_api)( REFCLSID, REFIID, void ** );

static IXThreadingImpl *threading;
static IXStoreImpl6 *store;
static IXUserImpl6 *user;
static XStoreContextHandle context;

static HRESULT wait_for( XAsyncBlock *async )
{
    return IXThreadingImpl_XAsyncGetStatus( threading, async, TRUE );
}

static BOOLEAN __stdcall print_product( const XStoreProduct *product, void *what )
{
    UINT32 i, owned_skus = 0;
    for (i = 0; i < product->skusCount; i++)
        if (product->skus[i].isInUserCollection && product->skus[i].collectionData.quantity == 1) owned_skus++;
    printf( "%s %s kind=%u owned=%d skus=%u owned_skus=%u\n", (const char *)what, product->storeId,
            product->productKind, product->isInUserCollection, product->skusCount, owned_skus );
    return TRUE;
}

static void products( const char *what, HRESULT hr, XAsyncBlock *async,
                      HRESULT (STDMETHODCALLTYPE *result)( IXStoreImpl6 *, XAsyncBlock *, XStoreProductQueryHandle * ) )
{
    XStoreProductQueryHandle query = NULL;

    if (SUCCEEDED(hr)) hr = wait_for( async );
    if (SUCCEEDED(hr)) hr = result( store, async, &query );
    printf( "%s-hr %#lx\n", what, hr );
    while (SUCCEEDED(hr) && query)
    {
        XAsyncBlock next = {0};
        XStoreProductQueryHandle more = NULL;

        IXStoreImpl6_XStoreEnumerateProductsQuery( store, query, (void *)what, print_product );
        if (!IXStoreImpl6_XStoreProductsQueryHasMorePages( store, query )) break;
        hr = IXStoreImpl6_XStoreProductsQueryNextPageAsync( store, query, &next );
        if (SUCCEEDED(hr)) hr = wait_for( &next );
        if (SUCCEEDED(hr)) hr = IXStoreImpl6_XStoreProductsQueryNextPageResult( store, &next, &more );
        IXStoreImpl6_XStoreCloseProductsQueryHandle( store, query );
        query = SUCCEEDED(hr) ? more : NULL;
    }
    if (query) IXStoreImpl6_XStoreCloseProductsQueryHandle( store, query );
}

static void addon_licences( void )
{
    XStoreAddonLicense *licences;
    XAsyncBlock async = {0};
    UINT32 i, count = 0;
    HRESULT hr;

    hr = IXStoreImpl6_XStoreQueryAddOnLicensesAsync( store, context, &async );
    if (SUCCEEDED(hr)) hr = wait_for( &async );
    if (SUCCEEDED(hr)) hr = IXStoreImpl6_XStoreQueryAddOnLicensesResultCount( store, &async, &count );
    printf( "licences-hr %#lx count %u\n", hr, count );
    if (FAILED(hr)) return;
    if (!count)
    {
        printf( "licences-result-hr %#lx\n", IXStoreImpl6_XStoreQueryAddOnLicensesResult( store, &async, 0, NULL ) );
        return;
    }
    licences = calloc( count, sizeof(*licences) );
    hr = IXStoreImpl6_XStoreQueryAddOnLicensesResult( store, &async, count, licences );
    printf( "licences-result-hr %#lx\n", hr );
    for (i = 0; SUCCEEDED(hr) && i < count; i++)
        printf( "licence %.*s active=%d expires=%lld offer=%s\n", 18, licences[i].skuStoreId, licences[i].isActive,
                (long long)licences[i].expirationDate, licences[i].inAppOfferToken[0] ? "yes" : "no" );
    free( licences );
}

static void picture( XUserGamerPictureSize size )
{
    XAsyncBlock async = {0};
    SIZE_T length = 0, used = 0;
    unsigned char *png = NULL;
    HRESULT hr;

    hr = IXUserImpl6_XUserGetGamerPictureAsync( user, NULL, size, &async );
    if (SUCCEEDED(hr)) hr = wait_for( &async );
    if (SUCCEEDED(hr)) hr = IXUserImpl6_XUserGetGamerPictureResultSize( user, &async, &length );
    if (SUCCEEDED(hr) && !(png = malloc( length ))) hr = E_OUTOFMEMORY;
    if (SUCCEEDED(hr)) hr = IXUserImpl6_XUserGetGamerPictureResult( user, &async, length, png, &used );
    if (SUCCEEDED(hr) && used >= 24 && !memcmp( png, "\x89PNG\r\n\x1a\n", 8 ))
        printf( "picture size=%d hr %#lx bytes=%Iu png %ux%u\n", size, hr, used,
                (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19],
                (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23] );
    else
        printf( "picture size=%d hr %#lx bytes=%Iu not-a-png\n", size, hr, used );
    free( png );
}

int main( void )
{
    XAsyncBlock listing = {0}, entitled = {0};
    HMODULE runtime = LoadLibraryA( "xgameruntime.dll" );
    query_api query = runtime ? (query_api)(void *)GetProcAddress( runtime, "QueryApiImpl" ) : NULL;
    HRESULT hr;

    if (!query) { printf( "no xgameruntime.dll\n" ); return 1; }
    if (FAILED(hr = query( &CLSID_XThreadingImpl, &IID_IXThreadingImpl, (void **)&threading )) ||
        FAILED(hr = query( &CLSID_XStoreImpl, &IID_IXStoreImpl6, (void **)&store )) ||
        FAILED(hr = query( &CLSID_XUserImpl, &IID_IXUserImpl6, (void **)&user )))
    { printf( "no runtime interfaces (%#lx)\n", hr ); return 1; }
    if (FAILED(hr = IXStoreImpl6_XStoreCreateContext( store, NULL, &context )))
    { printf( "no store context (%#lx)\n", hr ); return 1; }

    products( "listing", IXStoreImpl6_XStoreQueryAssociatedProductsAsync( store, context, XStoreProductKind_Durable, 100, &listing ),
              &listing, store->lpVtbl->XStoreQueryAssociatedProductsResult );
    products( "entitled", IXStoreImpl6_XStoreQueryEntitledProductsAsync( store, context, XStoreProductKind_Game | XStoreProductKind_Durable, 100, &entitled ),
              &entitled, store->lpVtbl->XStoreQueryEntitledProductsResult );
    addon_licences();
    picture( XUserGamerPictureSize_Small );
    picture( XUserGamerPictureSize_Medium );
    picture( XUserGamerPictureSize_Large );
    picture( XUserGamerPictureSize_ExtraLarge );
    printf( "done\n" );
    return 0;
}
