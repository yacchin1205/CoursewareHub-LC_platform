<?php
require_once __DIR__ . '/../../../lti/vendor/autoload.php';
require_once __DIR__ . '/../../../lib/lti/db.php';
require_once __DIR__ . '/../../../lib/hub-const.php';
require_once __DIR__ . '/../../../lib/functions.php';

@session_start();

$username = $_SESSION['username'];
header("X-Accel-Redirect: /entrance/");
header("X-Reproxy-URL: ".HUB_URL.'/'.COURSE_NAME."/hub/login");
header("X-REMOTE-USER: $username");
exit;
?>
