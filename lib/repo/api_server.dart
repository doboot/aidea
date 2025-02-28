import 'dart:convert';

import 'package:askaide/helper/constant.dart';
import 'package:askaide/helper/error.dart';
import 'package:askaide/helper/http.dart';
import 'package:askaide/helper/logger.dart';
import 'package:askaide/helper/platform.dart';
import 'package:askaide/repo/api/creative.dart';
import 'package:askaide/repo/api/image_model.dart';
import 'package:askaide/repo/api/info.dart';
import 'package:askaide/repo/api/page.dart';
import 'package:askaide/repo/api/payment.dart';
import 'package:askaide/repo/api/quota.dart';
import 'package:askaide/repo/api/room_gallery.dart';
import 'package:askaide/repo/api/user.dart';
import 'package:askaide/repo/settings_repo.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

class APIServer {
  /// 单例
  static final APIServer _instance = APIServer._internal();
  APIServer._internal();

  factory APIServer() {
    return _instance;
  }

  late String url;
  late String apiToken;
  late String language;

  init(SettingRepository setting) {
    apiToken = setting.stringDefault(settingAPIServerToken, '');
    language = setting.stringDefault(settingLanguage, 'zh');
    url = setting.stringDefault(settingServerURL, apiServerURL);

    setting.listen((settings, key, value) {
      if (key == settingAPIServerToken) {
        apiToken = settings.getDefault(settingAPIServerToken, '');
      }

      if (key == settingLanguage) {
        language = settings.getDefault(settingLanguage, 'zh');
      }

      if (key == settingServerURL) {
        url = settings.getDefault(settingServerURL, apiServerURL);
      }
    });
  }

  final List<DioErrorType> _retryableErrors = [
    DioErrorType.connectTimeout,
    DioErrorType.sendTimeout,
    DioErrorType.receiveTimeout,
  ];

  /// 异常处理
  Object _exceptionHandle(Object e) {
    Logger.instance.e(e);

    if (e is DioError) {
      if (e.response != null) {
        final resp = e.response!;

        if (resp.data is Map && resp.data['error'] != null) {
          return resp.data['error'] ?? e.toString();
        }

        if (resp.statusCode != null) {
          final ret = resolveHTTPStatusCode(resp.statusCode!);
          if (ret != null) {
            return ret;
          }
        }

        return resp.statusMessage ?? e.toString();
      }

      if (_retryableErrors.contains(e.type)) {
        return '请求超时，请重试';
      }
    }

    return e.toString();
  }

  Options _buildRequestOptions({int? requestTimeout = 10000}) {
    return Options(
      headers: _buildAuthHeaders(),
      receiveDataWhenStatusError: true,
      sendTimeout: requestTimeout,
      receiveTimeout: requestTimeout,
    );
  }

  Map<String, dynamic> _buildAuthHeaders() {
    final headers = <String, dynamic>{
      'X-CLIENT-VERSION': clientVersion,
      'X-PLATFORM': PlatformTool.operatingSystem(),
      'X-PLATFORM-VERSION': PlatformTool.operatingSystemVersion(),
      'X-LANGUAGE': language,
    };

    if (apiToken == '') {
      return headers;
    }

    headers['Authorization'] = 'Bearer $apiToken';

    return headers;
  }

  /// 获取用户 ID，如果未登录则返回 null
  int? localUserID() {
    if (apiToken == '') {
      return null;
    }

    // 从 Jwt Token 中获取用户 ID
    final parts = apiToken.split('.');
    if (parts.length != 3) {
      return null;
    }

    final payload = parts[1];
    final normalized = base64.normalize(payload);
    final resp = utf8.decode(base64.decode(normalized));
    final data = jsonDecode(resp);
    return data['id'];
  }

  Future<T> sendGetRequest<T>(
    String endpoint,
    T Function(dynamic) parser, {
    Map<String, dynamic>? queryParameters,
    int? requestTimeout = 10000,
  }) async {
    return request(
      HttpClient.get(
        '$url$endpoint',
        queryParameters: queryParameters,
        options: _buildRequestOptions(requestTimeout: requestTimeout),
      ),
      parser,
    );
  }

  Future<T> sendCachedGetRequest<T>(
    String endpoint,
    T Function(dynamic) parser, {
    String? subKey,
    Duration duration = const Duration(days: 1),
    Map<String, dynamic>? queryParameters,
    bool forceRefresh = false,
  }) async {
    return request(
      HttpClient.getCached(
        '$url$endpoint',
        queryParameters: queryParameters,
        subKey: subKey,
        duration: duration,
        forceRefresh: forceRefresh,
        options: _buildRequestOptions(),
      ),
      parser,
    );
  }

  Future<T> sendPostRequest<T>(
    String endpoint,
    T Function(dynamic) parser, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? formData,
    VoidCallback? finallyCallback,
  }) async {
    return request(
      HttpClient.post(
        '$url$endpoint',
        queryParameters: queryParameters,
        formData: formData,
        options: _buildRequestOptions(),
      ),
      parser,
      finallyCallback: finallyCallback,
    );
  }

  Future<T> sendPutRequest<T>(
    String endpoint,
    T Function(dynamic) parser, {
    String? subKey,
    Duration duration = const Duration(days: 1),
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? formData,
    bool forceRefresh = false,
    VoidCallback? finallyCallback,
  }) async {
    return request(
      HttpClient.put(
        '$url$endpoint',
        queryParameters: queryParameters,
        formData: formData,
        options: _buildRequestOptions(),
      ),
      parser,
      finallyCallback: finallyCallback,
    );
  }

  Future<T> sendDeleteRequest<T>(
    String endpoint,
    T Function(dynamic) parser, {
    String? subKey,
    Duration duration = const Duration(days: 1),
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? formData,
    bool forceRefresh = false,
    VoidCallback? finallyCallback,
  }) async {
    return request(
      HttpClient.delete(
        '$url$endpoint',
        queryParameters: queryParameters,
        formData: formData,
        options: _buildRequestOptions(),
      ),
      parser,
      finallyCallback: finallyCallback,
    );
  }

  Future<T> request<T>(
    Future<Response<dynamic>> respFuture,
    T Function(dynamic) parser, {
    VoidCallback? finallyCallback,
  }) async {
    try {
      final resp = await respFuture;
      if (resp.statusCode != 200) {
        return Future.error(resp.data['error']);
      }

      // Logger.instance.d("API Response: ${resp.data}");

      return parser(resp);
    } catch (e) {
      return Future.error(_exceptionHandle(e));
    } finally {
      finallyCallback?.call();
    }
  }

  String? _cacheSubKey() {
    final localUserId = localUserID();
    if (localUserId == null) {
      return null;
    }

    return 'local-uid=$localUserId';
  }

  /// 用户配额详情
  Future<QuotaResp?> quotaDetails() async {
    return sendGetRequest(
      '/v1/users/quota',
      (resp) => QuotaResp.fromJson(resp.data),
    );
  }

  /// 用户信息
  Future<UserInfo?> userInfo({bool cache = true}) async {
    return sendCachedGetRequest(
      '/v1/users/current',
      (resp) => UserInfo.fromJson(resp.data),
      duration: const Duration(minutes: 1),
      subKey: _cacheSubKey(),
      forceRefresh: !cache,
    );
  }

  /// 检查手机号是否存在
  Future<UserExistenceResp> checkPhoneExists(String username) async {
    return sendPostRequest(
      '/v1/auth/2in1/check',
      (resp) => UserExistenceResp.fromJson(resp.data),
      formData: Map<String, dynamic>.from({
        'username': username,
      }),
    );
  }

  /// 手机登录或者注册账号
  Future<SignInResp> signInOrUp({
    required String username,
    required String verifyCodeId,
    required String verifyCode,
    String? inviteCode,
  }) async {
    return sendPostRequest(
      '/v1/auth/2in1/sign-inup',
      (resp) => SignInResp.fromJson(resp.data),
      formData: Map<String, dynamic>.from({
        'username': username,
        'verify_code_id': verifyCodeId,
        'verify_code': verifyCode,
        'invite_code': inviteCode,
      }),
    );
  }

  /// 使用密码登录
  Future<SignInResp> signInWithPassword(
      String username, String password) async {
    return sendPostRequest(
      '/v1/auth/sign-in',
      (resp) => SignInResp.fromJson(resp.data),
      formData: Map<String, dynamic>.from({
        'username': username,
        'password': password,
      }),
    );
  }

  /// 使用 Apple 账号登录
  Future<SignInResp> signInWithApple({
    required String userIdentifier,
    String? givenName,
    String? familyName,
    String? email,
    String? authorizationCode,
    String? identityToken,
  }) async {
    return sendPostRequest(
      '/v1/auth/sign-in-apple/',
      (resp) => SignInResp.fromJson(resp.data),
      formData: Map<String, dynamic>.from({
        'user_identifier': userIdentifier,
        'given_name': givenName,
        'family_name': familyName,
        'email': email,
        'authorization_code': authorizationCode,
        'identity_token': identityToken,
        'is_ios': PlatformTool.isIOS() || PlatformTool.isMacOS(),
      }),
    );
  }

  /// 获取代理服务器列表
  Future<List<String>> proxyServers(String service) async {
    return sendCachedGetRequest(
      '/v1/proxy/servers',
      (resp) =>
          (resp['servers'][service] as List).map((e) => e.toString()).toList(),
      subKey: _cacheSubKey(),
    );
  }

  /// 获取模型列表
  Future<List<Model>> models() async {
    return sendCachedGetRequest(
      '/v1/models',
      (resp) {
        var models = <Model>[];
        for (var model in resp.data) {
          models.add(Model.fromJson(model));
        }

        return models;
      },
      subKey: _cacheSubKey(),
    );
  }

  /// 获取系统级提示语列表
  Future<List<Prompt>> prompts() async {
    return sendCachedGetRequest(
      '/v1/prompts',
      (resp) {
        var prompts = <Prompt>[];
        for (var prompt in resp.data) {
          prompts.add(Prompt(prompt['title'], prompt['content']));
        }

        return prompts;
      },
      subKey: _cacheSubKey(),
    );
  }

  /// 获取提示语示例
  Future<List<ChatExample>> examples() async {
    return sendCachedGetRequest(
      '/v1/examples',
      (resp) {
        var examples = <ChatExample>[];
        for (var example in resp.data) {
          examples.add(ChatExample(
            example['title'],
            content: example['content'],
            models: example['models'],
          ));
        }

        return examples;
      },
      subKey: _cacheSubKey(),
    );
  }

  ///   获取头像列表
  Future<List<String>> avatars() async {
    return sendCachedGetRequest(
      '/v1/images/avatar',
      (resp) {
        return (resp.data['avatars'] as List<dynamic>)
            .map((e) => e.toString())
            .toList();
      },
    );
  }

  ///  获取背景图列表
  Future<List<BackgroundImage>> backgrounds() async {
    return sendCachedGetRequest(
      '/v1/images/background',
      (resp) {
        var images = <BackgroundImage>[];
        for (var img in resp.data['preset']) {
          images.add(BackgroundImage.fromJson(img));
        }

        return images;
      },
    );
  }

  Future<TranslateText> translate(
    String text, {
    String from = 'auto',
  }) async {
    return sendPostRequest(
      '/v1/translate/',
      (resp) => TranslateText.fromJson(resp.data),
      formData: Map<String, dynamic>.from({
        'text': text,
        'from': from,
      }),
    );
  }

  /// 上传初始化
  Future<UploadInitResponse> uploadInit(
    String name,
    int filesize, {
    String? usage,
  }) async {
    return sendPostRequest(
      '/v1/storage/upload-init',
      (resp) => UploadInitResponse.fromJson(resp.data),
      formData: Map<String, dynamic>.from({
        'filesize': filesize,
        'name': name,
        'usage': usage,
      }),
    );
  }

  /// 获取模型支持的提示语示例
  Future<List<ChatExample>> exampleByTag(String tag) async {
    return sendCachedGetRequest(
      '/v1/examples/tags/$tag',
      (resp) {
        var examples = <ChatExample>[];
        for (var example in resp.data) {
          examples.add(ChatExample(
            example['title'],
            content: example['content'],
            models: ((example['models'] ?? []) as List<dynamic>)
                .map((e) => e.toString())
                .toList(),
          ));
        }
        return examples;
      },
      subKey: _cacheSubKey(),
    );
  }

  /// 获取模型支持的反向提示语示例
  Future<List<ChatExample>> negativePromptExamples(String tag) async {
    return sendCachedGetRequest(
      '/v1/examples/negative-prompts/$tag',
      (resp) {
        var examples = <ChatExample>[];
        for (var example in resp.data['data']) {
          examples.add(ChatExample(
            example['title'],
            content: example['content'],
          ));
        }
        return examples;
      },
      subKey: _cacheSubKey(),
    );
  }

  /// 获取模型支持的提示语示例
  Future<List<ChatExample>> example(String model) async {
    return sendCachedGetRequest(
      '/v1/examples/$model',
      (resp) {
        var examples = <ChatExample>[];
        for (var example in resp.data) {
          examples.add(ChatExample(
            example['title'],
            content: example['content'],
            models: ((example['models'] ?? []) as List<dynamic>)
                .map((e) => e.toString())
                .toList(),
          ));
        }
        return examples;
      },
      subKey: _cacheSubKey(),
    );
  }

  /// 模型风格列表
  Future<List<ModelStyle>> modelStyles(String category) async {
    return sendCachedGetRequest(
      '/v1/models/$category/styles',
      (resp) {
        var items = <ModelStyle>[];
        for (var item in resp.data) {
          items.add(ModelStyle.fromJson(item));
        }
        return items;
      },
      subKey: _cacheSubKey(),
    );
  }

  /// 创意岛项目列表
  Future<CreativeIslandItems> creativeIslandItems({
    required String mode,
    bool cache = true,
  }) async {
    return sendCachedGetRequest(
      '/v1/creative-island/items',
      (resp) {
        var items = <CreativeIslandItem>[];
        for (var item in resp.data['items']) {
          items.add(CreativeIslandItem.fromJson(item));
        }
        final categories = (resp.data['categories'] as List<dynamic>)
            .map((e) => e.toString())
            .toList();
        return CreativeIslandItems(
          items,
          categories,
          backgroundImage: resp.data['background_image'],
        );
      },
      queryParameters: <String, dynamic>{"mode": mode},
      duration: const Duration(minutes: 60),
      forceRefresh: !cache,
    );
  }

  /// 创意岛项目
  Future<CreativeIslandItem> creativeIslandItem(String id) async {
    return sendCachedGetRequest(
      '/v1/creative-island/items/$id',
      (resp) => CreativeIslandItem.fromJson(resp.data),
      subKey: _cacheSubKey(),
      duration: const Duration(minutes: 60),
    );
  }

  /// 创作岛生成消耗量预估
  Future<QuotaEvaluated> creativeIslandCompletionsEvaluate(
      String id, Map<String, dynamic> params) async {
    return sendPostRequest(
      '/v1/creative-island/completions/$id/evaluate',
      (resp) => QuotaEvaluated.fromJson(resp.data),
      formData: params,
    );
  }

  /// 创意岛项目生成数据
  Future<List<String>> creativeIslandCompletions(
      String id, Map<String, dynamic> params) async {
    return sendPostRequest(
      '/v1/creative-island/completions/$id',
      (resp) {
        final cicResp = CreativeIslandCompletionResp.fromJson(resp.data);
        switch (cicResp.type) {
          case creativeIslandCompletionTypeURLImage:
            return cicResp.resources;
          default:
            return <String>[cicResp.content];
        }
      },
      formData: params,
    );
  }

  /// 创意岛项目生成数据
  Future<String> creativeIslandCompletionsAsync(
      String id, Map<String, dynamic> params) async {
    params["mode"] = 'async';

    return sendPostRequest(
      '/v1/creative-island/completions/$id',
      (resp) {
        final cicResp = CreativeIslandCompletionAsyncResp.fromJson(resp.data);
        return cicResp.taskId;
      },
      formData: params,
    );
  }

  Future<QuotaEvaluated> creativeIslandCompletionsEvaluateV2(
      Map<String, dynamic> params) async {
    return sendPostRequest(
      '/v2/creative-island/completions/evaluate',
      (resp) => QuotaEvaluated.fromJson(resp.data),
      formData: params,
    );
  }

  Future<String> creativeIslandCompletionsAsyncV2(
      Map<String, dynamic> params) async {
    return sendPostRequest(
      '/v2/creative-island/completions',
      (resp) {
        final cicResp = CreativeIslandCompletionAsyncResp.fromJson(resp.data);
        return cicResp.taskId;
      },
      formData: params,
    );
  }

  Future<String> creativeIslandImageDirectEdit(
    String endpoint,
    Map<String, dynamic> params,
  ) async {
    return sendPostRequest(
      '/v2/creative-island/completions/$endpoint',
      (resp) {
        final cicResp = CreativeIslandCompletionAsyncResp.fromJson(resp.data);
        return cicResp.taskId;
      },
      formData: params,
    );
  }

  /// 模型风格列表
  Future<List<ModelStyle>> modelStylesV2({String? modelId}) async {
    return sendCachedGetRequest(
      '/v2/models/styles',
      (resp) {
        var items = <ModelStyle>[];
        for (var item in resp.data) {
          items.add(ModelStyle.fromJson(item));
        }
        return items;
      },
      queryParameters: {'model_id': modelId},
    );
  }

  /// 创作岛能力
  Future<CreativeIslandCapacity> creativeIslandCapacity(
      {required String mode, required String id}) async {
    return sendCachedGetRequest(
      '/v2/creative-island/capacity',
      (resp) {
        return CreativeIslandCapacity.fromJson(resp.data);
      },
      queryParameters: {'mode': mode, 'id': id},
    );
  }

  /// 异步任务执行状态查询
  Future<AsyncTaskResp> asyncTaskStatus(String taskId) async {
    return sendGetRequest(
      '/v1/tasks/$taskId/status',
      (resp) => AsyncTaskResp.fromJson(resp.data),
    );
  }

  /// 发送重置密码验证码
  Future<String> sendResetPasswordCodeForSignedUser() async {
    return sendPostRequest(
      '/v1/users/reset-password/sms-code',
      (resp) => resp.data['id'],
    );
  }

  /// 用户重置密码
  Future<void> resetPasswordByCodeSignedUser({
    required String password,
    required String verifyCodeId,
    required String verifyCode,
  }) async {
    return sendPostRequest(
      '/v1/users/reset-password',
      (resp) => resp.data['id'],
      formData: Map<String, dynamic>.from({
        'password': password,
        'verify_code_id': verifyCodeId,
        'verify_code': verifyCode,
      }),
    );
  }

  /// 使用邮箱验证码重置密码
  Future<void> resetPasswordByCode({
    required String username,
    required String password,
    required String verifyCodeId,
    required String verifyCode,
  }) async {
    return sendPostRequest(
      '/v1/auth/reset-password',
      (resp) => resp.data['id'],
      formData: Map<String, dynamic>.from({
        'username': username,
        'password': password,
        'verify_code_id': verifyCodeId,
        'verify_code': verifyCode,
      }),
    );
  }

  /// 发送找回密码验证码
  Future<String> sendResetPasswordCode(
    String username, {
    required String verifyType,
  }) async {
    return sendPostRequest(
      '/v1/auth/reset-password/$verifyType-code',
      (resp) => resp.data['id'],
      formData: Map<String, dynamic>.from({
        'username': username,
      }),
    );
  }

  /// 发送注册或者登录短信验证码
  Future<String> sendSigninOrSignupVerifyCode(
    String username, {
    required String verifyType,
    required bool isSignup,
  }) {
    if (isSignup) {
      return sendSignupVerifyCode(username, verifyType: verifyType);
    }

    return sendSigninVerifyCode(username, verifyType: verifyType);
  }

  /// 发送登录验证码
  Future<String> sendSigninVerifyCode(
    String username, {
    required String verifyType,
  }) async {
    return sendPostRequest(
      '/v1/auth/sign-in/$verifyType-code',
      (resp) => resp.data['id'],
      formData: Map<String, dynamic>.from({
        'username': username,
      }),
    );
  }

  /// 发送注册验证码
  Future<String> sendSignupVerifyCode(
    String username, {
    required String verifyType,
  }) async {
    return sendPostRequest(
      '/v1/auth/sign-up/$verifyType-code',
      (resp) => resp.data['id'],
      formData: Map<String, dynamic>.from({
        'username': username,
      }),
    );
  }

  /// 发送绑定手机号码验证码
  Future<String> sendBindPhoneCode(String username) async {
    return sendPostRequest(
      '/v1/auth/bind-phone/sms-code',
      (resp) => resp.data['id'],
      formData: Map<String, dynamic>.from({
        'username': username,
      }),
    );
  }

  /// 绑定手机号
  Future<SignInResp> bindPhone({
    required String username,
    required String verifyCodeId,
    required String verifyCode,
    String? inviteCode,
  }) async {
    return sendPostRequest(
      '/v1/auth/bind-phone',
      (resp) => SignInResp.fromJson(resp.data),
      formData: Map<String, dynamic>.from({
        'username': username,
        'verify_code_id': verifyCodeId,
        'verify_code': verifyCode,
        'invite_code': inviteCode,
      }),
    );
  }

  /// 注册账号
  Future<SignInResp> signupWithPassword({
    required String username,
    required String password,
    required String verifyCodeId,
    required String verifyCode,
    String? inviteCode,
  }) async {
    return sendPostRequest(
      '/v1/auth/sign-up',
      (resp) => SignInResp.fromJson(resp.data),
      formData: Map<String, dynamic>.from({
        'username': username,
        'password': password,
        'verify_code_id': verifyCodeId,
        'verify_code': verifyCode,
        'invite_code': inviteCode,
      }),
    );
  }

  /// 发送账号销毁手机验证码
  Future<String> sendDestroyAccountSMSCode() async {
    return sendPostRequest(
      '/v1/users/destroy/sms-code',
      (resp) => resp.data['id'],
    );
  }

  /// 账号销毁
  Future<void> destroyAccount({
    required String verifyCodeId,
    required String verifyCode,
  }) async {
    return sendDeleteRequest(
      '/v1/users/destroy',
      (resp) {},
      formData: Map<String, dynamic>.from({
        'verify_code_id': verifyCodeId,
        'verify_code': verifyCode,
      }),
    );
  }

  /// 版本检查
  Future<VersionCheckResp> versionCheck({bool cache = true}) async {
    return sendCachedGetRequest(
      '/public/info/version-check',
      (resp) => VersionCheckResp.fromJson(resp.data),
      queryParameters: Map<String, dynamic>.from({
        'version': clientVersion,
        'os': PlatformTool.operatingSystem(),
        'os_version': PlatformTool.operatingSystemVersion(),
      }),
      duration: const Duration(minutes: 180),
      forceRefresh: !cache,
    );
  }

  /// Apple 支付项目列表
  Future<ApplePayProducts> applePayProducts() async {
    return sendGetRequest(
      '/v1/payment/apple/products',
      (resp) => ApplePayProducts.fromJson(resp.data),
    );
  }

  /// 支付宝支付项目列表
  Future<ApplePayProducts> alipayProducts() async {
    return sendGetRequest(
      '/v1/payment/alipay/products',
      (resp) => ApplePayProducts.fromJson(resp.data),
    );
  }

  /// 发起 Apple Pay
  Future<String> createApplePay(String productId) async {
    return sendPostRequest(
      '/v1/payment/apple',
      (resp) => resp.data['id'],
      formData: Map<String, dynamic>.from({
        'product_id': productId,
      }),
    );
  }

  /// 发起 Alipay
  Future<AlipayCreatedReponse> createAlipay(String productId,
      {required String source}) async {
    return sendPostRequest(
      '/v1/payment/alipay',
      (resp) => AlipayCreatedReponse.fromJson(resp.data),
      formData: Map<String, dynamic>.from({
        'product_id': productId,
        'source': source,
      }),
    );
  }

  /// 支付宝支付客户端确认
  Future<String> alipayClientConfirm(Map<String, dynamic> params) async {
    return sendPostRequest(
      '/v1/payment/alipay/client-confirm',
      (resp) => resp.data['status'],
      formData: params,
    );
  }

  /// 查询支付状态
  Future<PaymentStatus> queryPaymentStatus(String paymentId) async {
    return sendGetRequest(
      '/v1/payment/status/$paymentId',
      (resp) => PaymentStatus.fromJson(resp.data),
    );
  }

  /// 更新 Apple Pay 支付信息
  Future<String> updateApplePay(
    String paymentId, {
    required String productId,
    required String? localVerifyData,
    required String? serverVerifyData,
    required String? verifyDataSource,
  }) async {
    return sendPutRequest(
      '/v1/payment/apple/$paymentId',
      (resp) => resp.data['status'],
      formData: Map<String, dynamic>.from({
        'product_id': productId,
        'local_verify_data': localVerifyData,
        'server_verify_data': serverVerifyData,
        'verify_data_source': verifyDataSource,
      }),
    );
  }

  /// 验证 Apple Pay 支付结果
  Future<String> verifyApplePay(
    String paymentId, {
    required String productId,
    required String? purchaseId,
    required String? transactionDate,
    required String? localVerifyData,
    required String? serverVerifyData,
    required String? verifyDataSource,
    required String status,
  }) async {
    return sendPostRequest(
      '/v1/payment/apple/$paymentId/verify',
      (resp) => resp.data['status'],
      formData: Map<String, dynamic>.from({
        'product_id': productId,
        'purchase_id': purchaseId,
        'transaction_date': transactionDate,
        'local_verify_data': localVerifyData,
        'server_verify_data': serverVerifyData,
        'verify_data_source': verifyDataSource,
        'status': status,
      }),
    );
  }

  /// 取消 Apple Pay
  Future<String> cancelApplePay(String paymentId, {String? reason}) async {
    return sendDeleteRequest(
      '/v1/payment/apple/$paymentId',
      (resp) => resp.data['status'],
      formData: Map<String, dynamic>.from({
        'reason': reason,
      }),
    );
  }

  /// 获取房间列表
  Future<RoomsResponse> rooms({bool cache = true}) async {
    return sendCachedGetRequest(
      '/v2/rooms',
      (resp) {
        return RoomsResponse.fromJson(resp.data);
      },
      subKey: _cacheSubKey(),
      forceRefresh: !cache,
    );
  }

  /// 获取单个房间信息
  Future<RoomInServer> room({required roomId, bool cache = true}) async {
    return sendCachedGetRequest(
      '/v1/rooms/$roomId',
      (resp) => RoomInServer.fromJson(resp.data),
      subKey: _cacheSubKey(),
      forceRefresh: !cache,
      duration: const Duration(minutes: 120),
    );
  }

  /// 创建房间
  Future<int> createRoom({
    required String name,
    required String model,
    required String vendor,
    String? description,
    String? systemPrompt,
    String? avatarUrl,
    int? avatarId,
    int? maxContext,
    String? initMessage,
  }) async {
    return sendPostRequest(
      '/v1/rooms',
      (resp) => resp.data["id"],
      formData: Map<String, dynamic>.from({
        'name': name,
        'model': model,
        'vendor': vendor,
        'description': description,
        'system_prompt': systemPrompt,
        'avatar_url': avatarUrl,
        'avatar_id': avatarId,
        'max_context': maxContext,
        'init_message': initMessage,
      }),
      finallyCallback: () {
        HttpClient.cacheManager
            .deleteByPrimaryKey('$url/v2/rooms', requestMethod: 'GET');
      },
    );
  }

  /// 更新房间信息
  Future<RoomInServer> updateRoom({
    required int roomId,
    required String name,
    required String model,
    required String vendor,
    String? description,
    String? systemPrompt,
    String? avatarUrl,
    int? avatarId,
    int? maxContext,
    String? initMessage,
  }) async {
    return sendPutRequest(
      '/v1/rooms/$roomId',
      (resp) => RoomInServer.fromJson(resp.data),
      formData: Map<String, dynamic>.from({
        'name': name,
        'model': model,
        'vendor': vendor,
        'description': description,
        'system_prompt': systemPrompt,
        'avatar_url': avatarUrl,
        'avatar_id': avatarId,
        'max_context': maxContext,
        'init_message': initMessage,
      }),
      finallyCallback: () {
        HttpClient.cacheManager
            .deleteByPrimaryKey('$url/v2/rooms', requestMethod: 'GET');
        HttpClient.cacheManager
            .deleteByPrimaryKey('$url/v1/rooms/$roomId', requestMethod: 'GET');
      },
    );
  }

  /// 删除房间
  Future<void> deleteRoom({required int roomId}) async {
    return sendDeleteRequest(
      '/v1/rooms/$roomId',
      (resp) {},
      finallyCallback: () {
        HttpClient.cacheManager
            .deleteByPrimaryKey('$url/v2/rooms', requestMethod: 'GET');
        HttpClient.cacheManager
            .deleteByPrimaryKey('$url/v1/rooms/$roomId', requestMethod: 'GET');
      },
    );
  }

  /// 创作岛 Gallery
  Future<List<CreativeItemInServer>> creativeUserGallery({
    required String mode,
    String? model,
    bool cache = true,
  }) async {
    return sendCachedGetRequest(
      '/v1/creative-island/gallery',
      (resp) {
        var res = <CreativeItemInServer>[];
        for (var item in resp.data['data']) {
          res.add(CreativeItemInServer.fromJson(item));
        }

        return res;
      },
      queryParameters: <String, dynamic>{"mode": mode, "model": model},
      forceRefresh: !cache,
      duration: const Duration(minutes: 30),
    );
  }

  /// 图片模型列表
  Future<List<ImageModel>> imageModels() async {
    return sendCachedGetRequest(
      '/v2/creative-island/models',
      (resp) {
        var res = <ImageModel>[];
        for (var item in resp.data['data']) {
          res.add(ImageModel.fromJson(item));
        }

        return res;
      },
      subKey: _cacheSubKey(),
    );
  }

  /// 图片模型滤镜列表（风格）
  Future<List<ImageModelFilter>> imageModelFilters() async {
    return sendCachedGetRequest(
      '/v2/creative-island/filters',
      (resp) {
        var res = <ImageModelFilter>[];
        for (var item in resp.data['data']) {
          res.add(ImageModelFilter.fromJson(item));
        }

        return res;
      },
      subKey: _cacheSubKey(),
    );
  }

  /// 创作岛历史记录（全量）
  Future<PagedData<CreativeItemInServer>> creativeHistories({
    String? mode,
    bool cache = true,
    int? page,
    int? perPage,
  }) async {
    return sendGetRequest(
      '/v2/creative-island/histories',
      (resp) {
        var filters = <int, String>{};
        for (var filter in resp.data['filters']) {
          filters[filter['id']] = filter['name'];
        }

        var res = <CreativeItemInServer>[];
        for (var item in resp.data['data']) {
          final ret = CreativeItemInServer.fromJson(item);
          if (ret.params['filter_id'] != null && filters.isNotEmpty) {
            ret.filterName = filters[ret.params['filter_id']];
          }

          res.add(ret);
        }

        return PagedData(
          data: res,
          page: resp.data['page'] ?? 1,
          perPage: resp.data['per_page'] ?? 20,
          total: resp.data['total'],
          lastPage: resp.data['last_page'],
        );
      },
      queryParameters: <String, dynamic>{
        "mode": mode,
        "page": page,
        "per_page": perPage,
      },
    );
  }

  /// 分享创作岛历史记录到 Gallery
  Future<void> shareCreativeHistoryToGallery({required int historyId}) {
    return sendPostRequest(
      '/v2/creative-island/histories/$historyId/share',
      (resp) {},
    );
  }

  /// 取消分享创作岛历史记录到 Gallery
  Future<void> cancelShareCreativeHistoryToGallery({required int historyId}) {
    return sendDeleteRequest(
      '/v2/creative-island/histories/$historyId/share',
      (resp) {},
    );
  }

  /// 封禁创作岛历史记录
  Future<void> forbidCreativeHistoryItem({required int historyId}) {
    return sendPutRequest(
      '/v1/admin/creative-island/histories/$historyId/forbid',
      (resp) {},
    );
  }

  /// 创作岛历史记录
  Future<List<CreativeItemInServer>> creativeItemHistories(String islandId,
      {bool cache = true}) async {
    return sendCachedGetRequest(
      '/v1/creative-island/items/$islandId/histories',
      (resp) {
        var res = <CreativeItemInServer>[];
        for (var item in resp.data['data']) {
          res.add(CreativeItemInServer.fromJson(item));
        }

        return res;
      },
      subKey: _cacheSubKey(),
      forceRefresh: !cache,
      duration: const Duration(minutes: 30),
    );
  }

  /// 获取创作岛项目历史详情
  Future<CreativeItemInServer> creativeHistoryItem({
    required hisId,
    bool cache = true,
  }) async {
    return sendCachedGetRequest(
      '/v2/creative-island/histories/$hisId',
      (resp) => CreativeItemInServer.fromJson(resp.data),
      subKey: _cacheSubKey(),
      forceRefresh: !cache,
      duration: const Duration(minutes: 1),
    );
  }

  /// 删除创作岛项目历史记录
  Future<void> deleteCreativeHistoryItem(String islandId,
      {required hisId}) async {
    return sendDeleteRequest(
      '/v1/creative-island/items/$islandId/histories/$hisId',
      (resp) {},
    );
  }

  /// 获取用户智慧果消耗历史记录
  Future<List<QuotaUsageInDay>> quotaUsedStatistics({bool cache = true}) async {
    return sendCachedGetRequest(
      '/v1/users/quota/usage-stat',
      (resp) {
        var res = <QuotaUsageInDay>[];
        for (var item in resp.data['usages']) {
          res.add(QuotaUsageInDay.fromJson(item));
        }

        return res;
      },
      subKey: _cacheSubKey(),
      forceRefresh: !cache,
      duration: const Duration(minutes: 30),
    );
  }

  Future<PagedData<CreativeGallery>> creativeGallery({
    bool cache = true,
    int page = 1,
    int perPage = 20,
  }) async {
    return sendCachedGetRequest(
      '/v1/creatives/gallery',
      (resp) {
        var res = <CreativeGallery>[];
        for (var item in resp.data['data']) {
          res.add(CreativeGallery.fromJson(item));
        }

        return PagedData(
          page: resp.data['page'] ?? 1,
          perPage: resp.data['per_page'] ?? 20,
          total: resp.data['total'],
          lastPage: resp.data['last_page'],
          data: res,
        );
      },
      queryParameters: Map.of({
        'page': page,
        'per_page': perPage,
      }),
      forceRefresh: !cache,
      duration: const Duration(minutes: 60),
    );
  }

  Future<CreativeGallery> creativeGalleryItem({
    required int id,
    bool cache = true,
  }) async {
    return sendCachedGetRequest(
      '/v1/creatives/gallery/$id',
      (resp) => CreativeGallery.fromJson(resp.data),
      forceRefresh: !cache,
      duration: const Duration(minutes: 30),
    );
  }

  /// 文本转语音
  Future<List<String>> textToVoice({required String text}) async {
    return sendPostRequest(
      '/v1/voice/text2voice',
      formData: {'text': text},
      (resp) => (resp.data['results'] as List<dynamic>)
          .map((e) => e.toString())
          .toList(),
    );
  }

  /// 故障日志上报
  Future<void> diagnosisUpload({required String data}) async {
    // data 从尾部开始截取 5000 个字符
    if (data.length > 5000) {
      data = data.substring(data.length - 5000);
    }

    return sendPostRequest(
      '/v1/diagnosis/upload',
      formData: {'data': data},
      (resp) {},
    );
  }

  /// 获取分享信息
  Future<ShareInfo> shareInfo() async {
    return sendCachedGetRequest(
      '/public/share/info',
      (resp) => ShareInfo.fromJson(resp.data),
      duration: const Duration(minutes: 30),
      subKey: _cacheSubKey(),
    );
  }

  Future<RoomGalleryResponse> roomGalleries({bool cache = true}) async {
    return sendCachedGetRequest(
      '/v1/room-galleries',
      (resp) {
        return RoomGalleryResponse.fromJson(resp.data);
      },
      subKey: _cacheSubKey(),
      forceRefresh: !cache,
    );
  }

  Future<RoomGallery> roomGalleryItem(
      {required int id, bool cache = true}) async {
    return sendCachedGetRequest(
      '/v1/room-galleries/$id',
      (resp) => RoomGallery.fromJson(resp.data),
      subKey: _cacheSubKey(),
      forceRefresh: !cache,
    );
  }

  Future<void> copyRoomGallery({required List<int> ids}) async {
    return sendPostRequest(
      '/v1/room-galleries/copy',
      formData: {'ids': ids.join(',')},
      (resp) {},
    );
  }

  Future<List<CreativeIslandItemV2>> creativeIslandItemsV2(
      {bool cache = true}) async {
    return sendCachedGetRequest(
      '/v2/creative/items',
      (resp) {
        var items = <CreativeIslandItemV2>[];
        for (var item in resp.data['data']) {
          items.add(CreativeIslandItemV2.fromJson(item));
        }
        return items;
      },
      subKey: _cacheSubKey(),
      forceRefresh: !cache,
    );
  }

  /// 绘图提示语 Tags
  Future<List<PromptCategory>> drawPromptTags({bool cache = true}) async {
    return sendCachedGetRequest(
      '/v1/examples/draw/prompt-tags',
      (resp) {
        var items = <PromptCategory>[];
        for (var item in resp.data['data']) {
          items.add(PromptCategory.fromJson(item));
        }
        return items;
      },
      subKey: _cacheSubKey(),
      forceRefresh: !cache,
    );
  }

  /// 更新用户头像
  Future<void> updateUserAvatar({required String avatarURL}) async {
    return sendPostRequest(
      '/v1/users/current/avatar',
      (resp) {},
      formData: {'avatar_url': avatarURL},
      finallyCallback: () {
        HttpClient.cacheManager
            .deleteByPrimaryKey('$url/v1/users/current', requestMethod: 'GET');
      },
    );
  }

  /// 更新用户昵称
  Future<void> updateUserRealname({required String realname}) async {
    return sendPostRequest(
      '/v1/users/current/realname',
      (resp) {},
      formData: {'realname': realname},
      finallyCallback: () {
        HttpClient.cacheManager
            .deleteByPrimaryKey('$url/v1/users/current', requestMethod: 'GET');
      },
    );
  }

  /// 服务器支持的能力
  Future<Capabilities> capabilities() async {
    return sendGetRequest(
      '/public/info/capabilities',
      (resp) => Capabilities.fromJson(resp.data),
      requestTimeout: 5000,
    );
  }

  /// 用户免费聊天次数统计
  Future<List<FreeModelCount>> userFreeStatistics() async {
    return sendGetRequest(
      '/v1/users/stat/free-chat-counts',
      (resp) {
        var items = <FreeModelCount>[];
        for (var item in resp.data['data']) {
          items.add(FreeModelCount.fromJson(item));
        }
        return items;
      },
    );
  }

  /// 用户免费聊天次数统计(单个模型)
  Future<FreeModelCount> userFreeStatisticsForModel(
      {required String model}) async {
    return sendGetRequest(
      '/v1/users/stat/free-chat-counts/$model',
      (resp) => FreeModelCount.fromJson(resp.data),
    );
  }

  /// 通知信息（促销事件）
  Future<Map<String, List<PromotionEvent>>> notificationPromotionEvents(
      {bool cache = true}) async {
    return sendCachedGetRequest(
      '/v1/notifications/promotions',
      (value) {
        var res = <String, List<PromotionEvent>>{};
        for (var item in value.data['data']) {
          if (res[item['id']] == null) {
            res[item['id']] = [];
          }

          res[item['id']] = [
            ...res[item['id']]!,
            PromotionEvent.fromJson(item),
          ];
        }

        return res;
      },
      subKey: _cacheSubKey(),
      forceRefresh: !cache,
    );
  }
}

enum PromotionEventClickButtonType {
  none,
  url,
  inAppRoute;

  static PromotionEventClickButtonType fromName(String typeName) {
    switch (typeName) {
      case 'url':
        return PromotionEventClickButtonType.url;
      case 'in_app_route':
        return PromotionEventClickButtonType.inAppRoute;
      default:
        return PromotionEventClickButtonType.none;
    }
  }

  String toName() {
    switch (this) {
      case PromotionEventClickButtonType.url:
        return 'url';
      case PromotionEventClickButtonType.inAppRoute:
        return 'in_app_route';
      default:
        return 'none';
    }
  }
}

class PromotionEvent {
  String? title;
  String content;
  PromotionEventClickButtonType clickButtonType;
  String? clickValue;
  String? clickButtonColor;
  String? backgroundImage;
  String? textColor;
  bool closeable;
  int? maxCloseDurationInDays;

  PromotionEvent({
    this.title,
    required this.content,
    required this.clickButtonType,
    this.clickValue,
    this.clickButtonColor,
    this.backgroundImage,
    this.textColor,
    required this.closeable,
    this.maxCloseDurationInDays,
  });

  toJson() => {
        'title': title,
        'content': content,
        'click_button_type': clickButtonType.toName(),
        'click_value': clickValue,
        'click_button_color': clickButtonColor,
        'background_image': backgroundImage,
        'text_color': textColor,
        'closeable': closeable,
        'max_close_duration_in_days': maxCloseDurationInDays,
      };

  static PromotionEvent fromJson(Map<String, dynamic> json) {
    return PromotionEvent(
      title: json['title'],
      content: json['content'],
      clickButtonType: PromotionEventClickButtonType.fromName(
          json['click_button_type'] ?? ''),
      clickValue: json['click_value'],
      clickButtonColor: json['click_button_color'],
      backgroundImage: json['background_image'],
      textColor: json['text_color'],
      closeable: json['closeable'] ?? false,
      maxCloseDurationInDays: json['max_close_duration_in_days'],
    );
  }
}

class ShareInfo {
  String qrCode;
  String message;
  String? inviteCode;

  ShareInfo({
    required this.qrCode,
    required this.message,
    this.inviteCode,
  });

  toJson() => {
        'qr_code': qrCode,
        'message': message,
        'invite_code': inviteCode,
      };

  static ShareInfo fromJson(Map<String, dynamic> json) {
    return ShareInfo(
      qrCode: json['qr_code'],
      message: json['message'],
      inviteCode: json['invite_code'],
    );
  }
}

class QuotaUsageInDay {
  String date;
  int used;

  QuotaUsageInDay({
    required this.date,
    required this.used,
  });

  toJson() => {
        'date': date,
        'used': used,
      };

  static QuotaUsageInDay fromJson(Map<String, dynamic> json) {
    return QuotaUsageInDay(
      date: json['date'],
      used: json['used'],
    );
  }
}

class RoomsResponse {
  List<RoomInServer> rooms;
  List<RoomGallery>? suggests;

  RoomsResponse({
    required this.rooms,
    this.suggests,
  });

  toJson() => {
        'rooms': rooms,
        'suggests': suggests,
      };

  static RoomsResponse fromJson(Map<String, dynamic> json) {
    var rooms = <RoomInServer>[];
    for (var item in json['data'] ?? []) {
      rooms.add(RoomInServer.fromJson(item));
    }

    var suggests = <RoomGallery>[];
    for (var item in json['suggests'] ?? []) {
      suggests.add(RoomGallery.fromJson(item));
    }

    return RoomsResponse(
      rooms: rooms,
      suggests: suggests,
    );
  }
}

class RoomInServer {
  int id;
  int userId;
  int avatarId;
  String? avatarUrl;
  String name;
  String? description;
  int? priority;
  String model;
  String vendor;
  String? systemPrompt;
  String? initMessage;
  int maxContext;
  int? maxTokens;
  DateTime? lastActiveTime;
  DateTime? createdAt;
  DateTime? updatedAt;

  RoomInServer({
    required this.id,
    required this.userId,
    required this.avatarId,
    required this.name,
    required this.maxContext,
    this.avatarUrl,
    this.description,
    this.priority,
    required this.model,
    required this.vendor,
    this.systemPrompt,
    this.initMessage,
    this.lastActiveTime,
    this.createdAt,
    this.updatedAt,
    this.maxTokens,
  });

  toJson() => {
        'id': id,
        'user_id': userId,
        'avatar_id': avatarId,
        'avatar_url': avatarUrl,
        'name': name,
        'description': description,
        'priority': priority,
        'model': model,
        'vendor': vendor,
        'init_message': initMessage,
        'max_context': maxContext,
        'max_tokens': maxTokens,
        'system_prompt': systemPrompt,
        'last_active_time': lastActiveTime?.toIso8601String(),
        'created_at': createdAt?.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      };

  static RoomInServer fromJson(Map<String, dynamic> json) {
    return RoomInServer(
      id: json['id'],
      userId: json['user_id'],
      avatarId: json['avatar_id'] ?? 0,
      avatarUrl: json['avatar_url'],
      name: json['name'],
      description: json['description'],
      priority: json['priority'],
      model: json['model'],
      vendor: json['vendor'],
      systemPrompt: json['system_prompt'],
      initMessage: json['init_message'],
      maxContext: json['max_context'] ?? 10,
      maxTokens: json['max_tokens'],
      lastActiveTime: json['last_active_time'] != null
          ? DateTime.parse(json['last_active_time'])
          : null,
      createdAt:
          json['CreatedAt'] != null ? DateTime.parse(json['CreatedAt']) : null,
      updatedAt:
          json['UpdatedAt'] != null ? DateTime.parse(json['UpdatedAt']) : null,
    );
  }
}

class VersionCheckResp {
  bool hasUpdate;
  String serverVersion;
  bool forceUpdate;
  String url;
  String message;

  VersionCheckResp({
    required this.hasUpdate,
    required this.serverVersion,
    required this.forceUpdate,
    required this.url,
    required this.message,
  });

  toJson() => {
        'has_update': hasUpdate,
        'server_version': serverVersion,
        'force_update': forceUpdate,
        'url': url,
        'message': message,
      };

  static VersionCheckResp fromJson(Map<String, dynamic> json) {
    return VersionCheckResp(
      hasUpdate: json['has_update'] ?? false,
      serverVersion: json['server_version'],
      forceUpdate: json['force_update'] ?? false,
      url: json['url'],
      message: json['message'],
    );
  }
}

class SignInResp {
  int id;
  String name;
  String? email;
  String? phone;
  String token;
  bool isNewUser;
  int reward;

  SignInResp({
    required this.id,
    required this.name,
    this.email,
    required this.token,
    this.phone,
    this.isNewUser = false,
    this.reward = 0,
  });

  toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'phone': phone,
        'token': token,
        'is_new_user': isNewUser,
        'reward': reward,
      };

  bool get needBindPhone => phone == null || phone!.isEmpty;

  static SignInResp fromJson(Map<String, dynamic> json) {
    return SignInResp(
      id: json['id'],
      name: json['name'],
      email: json['email'],
      phone: json['phone'],
      token: json['token'],
      isNewUser: json['is_new_user'] ?? false,
      reward: json['reward'] ?? 0,
    );
  }
}

class AsyncTaskResp {
  String status;
  List<String>? errors;
  List<String>? resources;
  String? originImage;

  AsyncTaskResp(this.status, {this.errors, this.resources, this.originImage});

  toJson() => {
        'status': status,
        'errors': errors,
        'resources': resources,
        'origin_image': originImage,
      };

  static AsyncTaskResp fromJson(Map<String, dynamic> json) {
    return AsyncTaskResp(
      json['status'],
      errors: json['errors'] != null
          ? (json['errors'] as List<dynamic>).map((e) => e.toString()).toList()
          : null,
      resources: json['resources'] != null
          ? (json['resources'] as List<dynamic>)
              .map((e) => e.toString())
              .toList()
          : null,
      originImage: json['origin_image'],
    );
  }
}

class Prompt {
  String title;
  String content;

  Prompt(this.title, this.content);

  toJson() {
    return {
      'title': title,
      'content': content,
    };
  }

  fromJson(Map<String, dynamic> json) {
    title = json['title'];
    content = json['content'];
  }
}

class ChatExample {
  String title;
  String? content;
  List<String> models;
  List<String> tags;

  ChatExample(
    this.title, {
    this.content,
    this.models = const [],
    this.tags = const [],
  });

  get text => content ?? title;

  toJson() => {
        'title': title,
        'content': content,
        'models': models,
        'tags': tags,
      };

  fromJson(Map<String, dynamic> json) {
    title = json['title'];
    content = json['content'];
    models = json['models'];
    tags = json['tags'];
  }
}

class TranslateText {
  String? result;
  String? speakUrl;

  TranslateText(this.result, this.speakUrl);

  toJson() => {
        'result': result,
        'speak_url': speakUrl,
      };

  static fromJson(Map<String, dynamic> json) {
    return TranslateText(json['result'], json['speak_url']);
  }
}

class UploadInitResponse {
  String bucket;
  String key;
  String token;
  String url;

  UploadInitResponse(this.key, this.bucket, this.token, this.url);

  toJson() => {
        'bucket': bucket,
        'key': key,
        'token': token,
        'url': url,
      };

  static fromJson(Map<String, dynamic> json) {
    return UploadInitResponse(
      json['key'],
      json['bucket'],
      json['token'],
      json['url'],
    );
  }
}

class ModelStyle {
  String id;
  String name;
  String? preview;

  ModelStyle({required this.id, required this.name, this.preview});

  toJson() => {
        'id': id,
        'name': name,
        'preview': preview,
      };

  static ModelStyle fromJson(Map<String, dynamic> json) {
    return ModelStyle(
      id: json['id'],
      name: json['name'],
      preview: json['preview'],
    );
  }
}

class Model {
  String id;
  String name;
  String? description;
  String category;
  bool isChat;
  bool isImage;
  bool disabled;
  String? tag;

  Model({
    required this.id,
    required this.name,
    required this.category,
    required this.isChat,
    required this.isImage,
    this.description,
    this.disabled = false,
    this.tag,
  });

  toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'category': category,
        'is_chat': isChat,
        'is_image': isImage,
        'disabled': disabled,
        'tag': tag,
      };

  static Model fromJson(Map<String, dynamic> json) {
    return Model(
      id: json['id'],
      name: json['name'],
      description: json['description'],
      category: json['category'],
      isChat: json['is_chat'],
      isImage: json['is_image'],
      disabled: json['disabled'] ?? false,
      tag: json['tag'],
    );
  }
}

class BackgroundImage {
  String url;
  String preview;

  BackgroundImage(this.url, this.preview);

  toJson() => {
        'url': url,
        'preview': preview,
      };

  static BackgroundImage fromJson(Map<String, dynamic> json) {
    return BackgroundImage(
      json['url'],
      json['preview'],
    );
  }
}

class UserExistenceResp {
  bool exist;
  String signInMethod;

  UserExistenceResp(this.exist, this.signInMethod);

  toJson() => {
        'exist': exist,
        'sign_in_method': signInMethod,
      };

  static UserExistenceResp fromJson(Map<String, dynamic> json) {
    return UserExistenceResp(
      json['exist'],
      json['sign_in_method'],
    );
  }
}

class PromptCategory {
  String name;
  List<PromptCategory> children;
  List<PromptTag> tags;

  PromptCategory(this.name, this.children, this.tags);

  toJson() => {
        'name': name,
        'children': children,
        'tags': tags,
      };

  static PromptCategory fromJson(Map<String, dynamic> json) {
    var children = <PromptCategory>[];
    for (var item in json['children'] ?? []) {
      children.add(PromptCategory.fromJson(item));
    }

    var tags = <PromptTag>[];
    for (var item in json['tags'] ?? []) {
      tags.add(PromptTag.fromJson(item));
    }

    return PromptCategory(
      json['name'],
      children,
      tags,
    );
  }
}

class PromptTag {
  String name;
  String value;

  PromptTag(this.name, this.value);

  toJson() => {
        'name': name,
        'value': value,
      };

  static PromptTag fromJson(Map<String, dynamic> json) {
    return PromptTag(
      json['name'],
      json['value'],
    );
  }
}

class FreeModelCount {
  String model;
  String name;
  int leftCount;
  int maxCount;
  String? info;

  FreeModelCount({
    required this.model,
    required this.name,
    required this.leftCount,
    required this.maxCount,
    this.info,
  });

  toJson() => {
        'model': model,
        'name': name,
        'left_count': leftCount,
        'max_count': maxCount,
        'info': info,
      };

  static FreeModelCount fromJson(Map<String, dynamic> json) {
    return FreeModelCount(
      model: json['model'],
      name: json['name'] ?? json['model'],
      leftCount: json['left_count'] ?? 0,
      maxCount: json['max_count'] ?? 0,
      info: json['info'],
    );
  }
}
