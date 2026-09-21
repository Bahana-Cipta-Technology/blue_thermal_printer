// Lihat atribusi lengkap di IWoyouService.aidl pada folder yang sama.
// Tidak dipakai langsung oleh SunmiPrinterBridge -- wajib ikut divendor karena
// dirujuk sebagai tipe parameter oleh IWoyouService.aidl.
package woyou.aidlservice.jiuiv5;

/**
 * 打印服务执行结果的回调
 */
interface ITax {

	oneway void onDataResult(in byte [] data);

}
