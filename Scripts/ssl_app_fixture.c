#include <curl/curl.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: TLSClient proxy ca-file url\n");
        return 64;
    }
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) return 70;
    CURL *client = curl_easy_init();
    if (!client) {
        curl_global_cleanup();
        return 70;
    }

    curl_easy_setopt(client, CURLOPT_PROXY, argv[1]);
    curl_easy_setopt(client, CURLOPT_NOPROXY, "");
    curl_easy_setopt(client, CURLOPT_CAINFO, argv[2]);
    curl_easy_setopt(client, CURLOPT_URL, argv[3]);
    curl_easy_setopt(client, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(client, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(client, CURLOPT_TIMEOUT, 8L);
    CURLcode result = curl_easy_perform(client);
    if (result != CURLE_OK) fprintf(stderr, "%s\n", curl_easy_strerror(result));

    curl_easy_cleanup(client);
    curl_global_cleanup();
    return result;
}
