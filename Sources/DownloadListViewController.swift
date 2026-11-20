import UIKit

final class DownloadListViewController: UITableViewController {

    private var items: [DownloadItem] = []
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "下载中心"
        tableView.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.12, alpha: 1)
        tableView.separatorStyle = .none
        tableView.register(DLCell.self, forCellReuseIdentifier: "cell")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭", style: .plain, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "打开相册", style: .plain, target: self, action: #selector(openGallery))
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.reload()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                              name: .zzDownloadsChanged, object: nil)
    }

    deinit { timer?.invalidate() }

    @objc private func close() { dismiss(animated: true) }

    @objc private func openGallery() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }

    @objc private func reload() {
        items = MediaDownloader.shared.snapshot()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        108
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! DLCell
        cell.bind(items[indexPath.row])
        cell.onAction = { [weak self] item in
            guard let self = self else { return }
            if item.finished {
                if item.state == .failed || item.state == .cancelled {
                    MediaDownloader.shared.retry(item)
                }
            } else {
                MediaDownloader.shared.cancel(item)
            }
            self.reload()
        }
        return cell
    }
}

final class DLCell: UITableViewCell {

    private let card = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let action = UIButton(type: .system)
    private var item: DownloadItem?
    var onAction: ((DownloadItem) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = UIColor(red: 0.11, green: 0.10, blue: 0.18, alpha: 1)
        card.layer.cornerRadius = 10
        contentView.addSubview(card)

        titleLabel.textColor = UIColor(white: 0.93, alpha: 1)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.numberOfLines = 2
        card.addSubview(titleLabel)

        statusLabel.textColor = UIColor(white: 0.62, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.numberOfLines = 2
        card.addSubview(statusLabel)

        bar.progressTintColor = UIColor(red: 0.49, green: 0.30, blue: 1.0, alpha: 1)
        bar.trackTintColor = UIColor(white: 1, alpha: 0.12)
        card.addSubview(bar)

        action.setTitleColor(UIColor(red: 1, green: 0.72, blue: 0.30, alpha: 1), for: .normal)
        action.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        action.addTarget(self, action: #selector(tap), for: .touchUpInside)
        card.addSubview(action)
    }

    required init?(coder: NSCoder) { fatalError() }

    func bind(_ item: DownloadItem) {
        self.item = item
        titleLabel.text = item.title
        switch item.state {
        case .waiting:
            statusLabel.text = "排队等待中"
            action.setTitle("取消", for: .normal)
        case .running:
            statusLabel.text = "后台下载中 \(item.progress)%"
            action.setTitle("取消", for: .normal)
        case .done:
            statusLabel.text = item.result ?? "已完成"
            action.setTitle("打开相册", for: .normal)
        case .failed:
            statusLabel.text = "失败：" + (item.error ?? "未知错误")
            action.setTitle("重试", for: .normal)
        default:
            statusLabel.text = "已取消"
            action.setTitle("重新下载", for: .normal)
        }
        bar.isHidden = item.finished
        bar.progress = Float(item.progress) / 100.0
        setNeedsLayout()
    }

    @objc private func tap() {
        guard let item = item else { return }
        if item.state == .done {
            if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            return
        }
        onAction?(item)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width - 24
        card.frame = CGRect(x: 12, y: 6, width: w, height: 96)
        titleLabel.frame = CGRect(x: 12, y: 10, width: w - 24, height: 38)
        statusLabel.frame = CGRect(x: 12, y: 48, width: w - 100, height: 30)
        bar.frame = CGRect(x: 12, y: 82, width: w - 24, height: 3)
        action.frame = CGRect(x: w - 92, y: 60, width: 80, height: 28)
    }
}
