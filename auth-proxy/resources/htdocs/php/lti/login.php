<?php
require_once __DIR__ . '/../../../lti/vendor/autoload.php';
require_once __DIR__ . '/../../../lib/lti/db.php';

@session_start();
session_regenerate_id(true);

use \IMSGlobal\LTI;

LTI\LTI_OIDC_Login::new(new CoursewareHub_Database())
    ->do_oidc_login_redirect(TOOL_HOST . "/php/lti/service.php")
    ->do_redirect();
?>
